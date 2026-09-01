# 007 — Why a teardown leaks AWS resources, and why `reclaimPolicy: Delete` does not save you

You said destroy-and-rebuild is your rhythm. This is the thing that quietly breaks it, and
the part I got wrong when I first explained the storage decision to you.

## The short version

**Kubernetes creates AWS resources that Terraform never sees.** Nothing in any state file
knows they exist. They are cleaned up by controllers running *inside* the cluster, so the
cleanup only happens while the cluster is still alive.

Destroy the cluster first and you get one of two failures, which are opposites:

- **LEAK** — the resource survives with nothing tracking it, billing forever
- **STUCK** — its network interface holds the subnet, so `terraform destroy` fails and the
  VPC cannot be removed until someone unpicks it by hand

## Who creates what

There are three actors, and only one of them is Terraform.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  TERRAFROM creates            │  and KNOWS about them                │
   │    VPC, subnets, NAT          │  they are in terraform.tfstate       │
   │    EKS cluster, node group    │  destroy removes them correctly      │
   │    StorageClass (the recipe)  │                                      │
   └──────────────────────────────────────────────────────────────────────┘
                                    │
                                    │  you apply a PVC or a Service
                                    ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │  A CONTROLLER INSIDE THE CLUSTER creates the real AWS resource       │
   │                                                                      │
   │    PersistentVolumeClaim  ──[ EBS CSI controller ]──▶  EBS volume    │
   │    Service type=LoadBalancer ──[ cloud controller ]──▶  ELB          │
   │    Ingress                ──[ ALB controller ]──────▶  ALB          │
   │                                                                      │
   │  NONE of these appear in ANY Terraform state.                        │
   │  Terraform created the cluster. The cluster created these.           │
   └──────────────────────────────────────────────────────────────────────┘
```

That middle arrow is the whole problem. Terraform asked for a cluster. The cluster asked AWS
for a load balancer. Terraform was never told.

## Why order is the lever

The controller is a program running on your nodes. It watches for the Kubernetes object
disappearing, and *then* calls the AWS API to delete the volume or the load balancer.

```
  CORRECT ORDER — the controller is alive to do its job

    1. delete the PVC          ─▶  CSI controller sees it, deletes the EBS volume  ✓
    2. delete the Service      ─▶  cloud controller sees it, deletes the ELB       ✓
    3. THEN destroy the cluster
    4. THEN destroy the VPC                                                        ✓


  WRONG ORDER — nothing is left to do the job

    1. destroy the cluster     ─▶  controllers die mid-reconcile
                                   EBS volume: still there, still billing
                                   ELB:        still there, still billing
                                   its ENI:    still attached to your subnet
    2. destroy the VPC         ─▶  DependencyViolation. Cannot delete subnet.      ✗
```

AWS documents both halves. From the
[EKS DeleteCluster reference](https://docs.aws.amazon.com/cli/latest/reference/eks/delete-cluster.html):
active services and ingresses tied to a load balancer must be deleted first, or you end up
with orphaned resources that block deleting the VPC. From the
[VPC user guide](https://docs.aws.amazon.com/vpc/latest/userguide/delete-vpc.html): anything
that created a requester-managed network interface has to go before the VPC can.

*Content was rephrased for compliance with licensing restrictions.*

## The correction I owe you

When I asked you to choose a PVC reclaim policy, I framed it as:

- `Delete` → **you lose the data**
- `Retain` → **the volume survives but becomes orphaned**

That framing is wrong, or at least incomplete, and in a way that matters.

**`reclaimPolicy: Delete` does not guarantee the volume is deleted.** It is an instruction to
the CSI controller describing what to do *when it processes a PVC deletion*. It is not a
property of the volume and AWS does not enforce it.

So if the cluster is destroyed while the PVC still exists, there is no controller left to
process anything, and a `Delete` volume leaks **exactly like** a `Retain` one:

| | PVC deleted while cluster is alive | Cluster destroyed with PVC still present |
|---|---|---|
| `reclaimPolicy: Delete` | volume deleted, data gone | **volume leaks, still billing** |
| `reclaimPolicy: Retain` | volume kept, data kept, orphaned | **volume leaks, still billing** |

Read the right-hand column: the reclaim policy makes no difference at all. **Ordering
decides whether anything gets cleaned up; the reclaim policy only decides what happens once
ordering is already right.**

That is why the fix is a guard on teardown order rather than a different reclaim policy.

## What it costs to get wrong

Verified for `eu-west-2` against the Pricing API:

| Leaked thing | Cost | How you notice |
|---|---|---|
| Network Load Balancer | **$0.02646/hr ≈ $19.32/mo** | you don't, until the bill |
| `gp3` volume | **$0.0928/GB-mo** | you don't |
| Unassociated Elastic IP | billed while idle | you don't |
| Orphaned ENI | free, but **blocks the VPC destroy** | immediately, as a confusing error |

The last row is the kindest failure, because it is loud.

## What now enforces this

`scripts/teardown_guard.py`, wired into `destroy-workloads.yml` before anything is touched.

**Guard 1 — layer order.** Reads the state of every layer above the one being destroyed. If
any still holds resources, it refuses:

```
  teardown guard: about to destroy 'platform'
  cluster-addons   4 resources STILL PRESENT      REFUSE
```

**Guard 2 — in-cluster objects.** Before destroying `platform`, checks the live cluster for
LoadBalancer Services, Ingresses and bound PVCs. Any of them means a leak is about to happen.

**A sweep**, also available as `make teardown-check`, listing what still costs money — so
after a teardown you can confirm nothing was left behind:

```
  EKS clusters             0   $0.10/hr each
  NAT gateways             0   $0.05/hr each
  load balancers           0   ~$19.32/mo each
  EBS volumes              0   of which detached: 0
  elastic IPs              0   of which unassociated: 0
```

A dry run only warns, since it mutates nothing and refusing would withhold the preview. The
real run is refused.

## A second lesson, found while testing the first

The sweep above was written to reassure you after a teardown. On its first real run against
expired credentials it printed this:

```
  EKS clusters             0   $0.10/hr each
  running EC2 instances    0
  NAT gateways             0   $0.05/hr each
  load balancers           0   ~$19.32/mo each
  EBS volumes              0   of which detached: 0
```

**A perfect clean bill of health, without one successful call to AWS.** The code read
`n = len(...) if rc == 0 else 0`, so every failure became a zero.

This is the same defect as the `-refresh=false` plan recorded as RC7 in the design: a check
that passes because it never read the thing it claims to have checked. It is arguably worse
than having no tool, because the output is confident.

It now says so:

```
  EKS clusters             ?   COULD NOT CHECK — ExpiredTokenException ...
  !! 7 of these could not be checked, so this is NOT an all-clear.
```

and exits non-zero, so nothing downstream can read "I could not look" as "nothing is
leaking". Pinned by a test that fails if any probe ever silently returns zero again.

**The general shape.** Any code of the form `value if call_succeeded else <default>` is
converting a failure into a fact. When the default happens to be the reassuring answer —
`0`, `[]`, `False`, `"healthy"` — the failure becomes invisible at exactly the moment it
matters. Absence of an answer and an answer of zero need to be different things in the type,
not merged by a convenient fallback.

## The safe rhythm

```
  TEARDOWN                              REBUILD
    apps                                  registry     (already there — skip)
      ↓                                     ↓
    cluster-addons                        platform     ~15-20 min
      ↓                                     ↓
    platform                              cluster-addons  ~30 sec
                                            ↓
    registry stays                        apps
```

`apps` must go first because it owns the PVCs and Services. Once those are gone through
Terraform — with the cluster still up, so the controllers can act — there is nothing left to
leak.

## The lesson under the lesson

A setting named `Delete` does not mean AWS will delete anything. It configures a program, and
a configured program that is no longer running configures nothing.

Worth asking of any "cleanup" or "retention" setting: **which process reads this, and is that
process alive at the moment it would need to act?** For in-cluster controllers during a
teardown, the answer is often no.
