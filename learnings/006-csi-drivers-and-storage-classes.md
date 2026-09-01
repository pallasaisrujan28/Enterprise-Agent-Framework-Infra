# 006 — Storage: CSI drivers, StorageClasses, and where a disk comes from

*Written 2026-09-01, rewritten the same day after the first version proved unclear about
the thing that actually matters: **who creates the disk**. Read from the live `eaf-dev`
cluster, Kubernetes 1.36, EBS CSI driver `v1.65.0-eksbuild.1`. Pricing from the AWS
Pricing API.*

## The questions

> what is this csi driver, can u explain me with diagram please. I am confusing, a
> automatic gp2 was created when we initialised the cluster

> the document is not clear on who creates storage, how is it mounted and used

> what is the use of EBS during the pod spin up?

> also mention what is storage classes?

## Start here: most pods never touch EBS

This is the fact that makes the rest make sense, and the first version of this document
buried it.

```
   ┌─ a pod with NO volume ────────────────────────────────────────┐
   │                                                               │
   │   Writes go to the NODE's own disk, in a scratch directory.    │
   │   Pod dies  ->  everything it wrote is GONE.                   │
   │   No EBS volume. Nothing created. Nothing to clean up.         │
   │                                                               │
   │   coredns · kube-proxy · the agent · Firecrawl's API           │
   └───────────────────────────────────────────────────────────────┘

   ┌─ a pod WITH a PersistentVolumeClaim ──────────────────────────┐
   │                                                               │
   │   A real EBS volume is created, attached to the node the pod   │
   │   landed on, and mounted into the container.                   │
   │   Pod dies and restarts  ->  THE DATA IS STILL THERE.          │
   │                                                               │
   │   Neo4j · Postgres · ClickHouse                                │
   └───────────────────────────────────────────────────────────────┘
```

**EBS is only involved when a pod has to remember something across restarts.** A
stateless pod never asks for a volume, so none of this machinery runs for it.

*Answering "what is the use of EBS during pod spin up": for most pods, none. For a
stateful one, it is the step that turns a directory inside the container into a disk that
outlives the container.*

## Three different things, and mixing them up is the whole confusion

```
   ┌────────────────┬──────────────────────────┬───────────────────────────┐
   │  StorageClass  │  a RECIPE                │  "how to make a disk"     │
   │                │  a template. Costs $0.   │                           │
   │                │  Creates nothing.        │                           │
   ├────────────────┼──────────────────────────┼───────────────────────────┤
   │  PVC           │  an ORDER                │  "I want 20Gi, using      │
   │                │  a request from a         │   that recipe"            │
   │                │  workload.                │                           │
   ├────────────────┼──────────────────────────┼───────────────────────────┤
   │  PV + EBS vol  │  the ACTUAL DISK         │  a real thing in AWS      │
   │                │  costs real money.       │  that you are billed for  │
   └────────────────┴──────────────────────────┴───────────────────────────┘
```

Right now this cluster has:

| | Count |
|---|---|
| StorageClasses (recipes) | 1 — `gp2` |
| PVCs (orders) | **0** |
| PVs / EBS volumes from a PVC (disks) | **0** |

So `gp2` is **an unused recipe sitting in a drawer.** It has created nothing and costs
nothing.

> The two EBS volumes you can see in the console are the nodes' own **root disks**
> (`/dev/xvda`, 50 GiB gp3). Those come from the node group's launch template — the
> `disk_size` input in `modules/eks-node-group`. They have nothing to do with
> StorageClasses, and no pod asked for them.

## What is a StorageClass?

**A named set of instructions for making a disk.** Nothing more.

```yaml
kind: StorageClass
metadata:
  name: gp3                            # the name a PVC asks for
provisioner: ebs.csi.aws.com           # WHICH driver does the work
parameters:                            # options that driver understands
  type: gp3
  encrypted: "true"
allowVolumeExpansion: true             # can this disk be grown later?
volumeBindingMode: WaitForFirstConsumer  # WHEN to create it
reclaimPolicy: Delete                  # what happens when the PVC is deleted
```

It exists so a workload can say *"give me 20Gi of the fast encrypted kind"* without
knowing it is on AWS. The same Helm chart asks for `storageClassName: gp3` on your cluster
and something else entirely on someone's on-prem cluster.

A cluster can mark **one** class as default, and then a PVC that names no class gets that
one.

## Who creates the disk? The full chain

This is the part the first version left vague. Follow the arrows — each one is a
different actor.

```
  ①  YOU write a PersistentVolumeClaim (usually inside a Helm chart)
      ┌────────────────────────────────────┐
      │ kind: PersistentVolumeClaim         │
      │ spec:                               │
      │   storageClassName: gp3   ─────────┐│
      │   resources:                       ││
      │     requests: { storage: 20Gi }    ││
      └────────────────────────────────────┘│
                    │                        │
                    │  "someone please make  │
                    │   me this disk"         │
                    ▼                        │
  ②  KUBERNETES looks up the recipe ◀────────┘
      StorageClass gp3 says: provisioner = ebs.csi.aws.com
                    │
                    ▼
  ③  ebs-csi-controller  (a POD, running in kube-system, 2 replicas)
      notices the PVC and calls the EC2 API:

           ec2:CreateVolume   size=20Gi  type=gp3  az=eu-west-2a
                    │
                    ▼
  ④  AWS creates a real EBS volume.  vol-0abc...  IN ONE AVAILABILITY ZONE.
      This is the moment you start being billed.
                    │
                    ▼
  ⑤  ebs-csi-controller calls the EC2 API again:

           ec2:AttachVolume   vol-0abc...  ->  i-0815...  as /dev/xvdba

      The volume is now a block device on that specific EC2 instance,
      exactly as if you had attached it by hand in the console.
                    │
                    ▼
  ⑥  ebs-csi-node  (a DaemonSet POD on that node) does the local work:
           - formats it (ext4) if it is brand new
           - mounts it into the node's filesystem
           - bind-mounts it into the container
                    │
                    ▼
  ⑦  /data inside the container IS the EBS volume.
      The application just sees a directory.
```

**So: the EBS volume is created by a pod running in your cluster, calling the EC2 API.**
Not by Terraform, not by the control plane, not by AWS on its own. That pod is the
`ebs-csi-controller`, and that is precisely why it needed an IAM role — it is making
`CreateVolume` and `AttachVolume` calls, and something has to authorise them.

## Now: what a CSI driver is, and why it exists

A **driver** is the thing that translates between Kubernetes' generic request and one
specific storage system.

Kubernetes has no idea what EBS is. It defines one interface — the **Container Storage
Interface** — with operations like `CreateVolume`, `ControllerPublishVolume` (attach) and
`NodePublishVolume` (mount). AWS writes a driver that implements those on one side and
calls the EC2 API on the other.

```
   Kubernetes  ──"CreateVolume"──▶  ┌─────────────┐ ──"ec2:CreateVolume"──▶  AWS
   (owns the interface)             │  EBS CSI    │
                                    │  driver     │  (AWS owns this)
                                    └─────────────┘

   the same interface, different plug:
                                    ┌─────────────┐
                                    │  EFS CSI    │ ──▶ Elastic File System
                                    └─────────────┘
```

**CSI is the plug socket. A driver is the plug.**

It used to be otherwise. Storage code for every vendor lived *inside the Kubernetes source
tree* — "in-tree". Two problems killed that: a bug in the AWS storage code needed a whole
**Kubernetes release** to fix, and every cluster on earth shipped code for every storage
vendor whether it used them or not.

Moving it out is why the driver is an **add-on** — software running in your cluster on its
own release schedule — and why it has its own IAM identity rather than borrowing the
control plane's.

### The driver has two halves, and only one needs AWS credentials

```
  ebs-csi-controller   Deployment, 2 replicas, runs anywhere
                       Calls the EC2 API: create, attach, delete, resize
                       NEEDS AWS CREDENTIALS  ← Pod Identity role +
                                                AmazonEBSCSIDriverPolicyV2

  ebs-csi-node         DaemonSet, one pod per node
                       Formats and mounts. Pure local kernel work.
                       NEEDS NO AWS CREDENTIALS
```

That split is why `modules/eks-addon` attaches a Pod Identity role for the service account
`ebs-csi-controller-sa` and nothing for the node half.

## `WaitForFirstConsumer`: the setting worth understanding

**An EBS volume lives in exactly one availability zone and can only attach to an instance
in that same zone.** That single fact drives the setting.

```
  Immediate                             WaitForFirstConsumer
  ─────────────────────────────         ─────────────────────────────
  ① volume created FIRST                ① pod is SCHEDULED first
     in whichever zone                      -> lands on a node in 2b
     the driver picks                    ② volume then created
                                            in 2b, to match
  ② scheduler must now find
     a node in THAT zone                 always attachable
        │
        ▼
  if every node in that zone is
  full: pod Pending forever, and
  the message talks about node
  affinity, not about storage
```

It is not a state a volume "goes into" — it is an instruction on the recipe about *when*
to create the disk. This is also why `modules/network` outputs
`private_subnet_ids_by_az`: anything stateful has to be able to agree with its volume
about a zone.

## The `gp2` class EKS created, and what we are doing about it

**We did not create it.** No Terraform of ours mentions it. **EKS adds a `gp2`
StorageClass to every new cluster** and has done since Kubernetes 1.11. It appeared the
moment the control plane came up.

Read live from the cluster:

```
NAME   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE     ALLOWVOLUMEEXPANSION
gp2    kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer  false
```

Four observations:

**It names the old in-tree provisioner**, `kubernetes.io/aws-ebs`. And that plugin is not
registered on the nodes at all:

```
NODE                                        DRIVERS
ip-10-0-32-154.eu-west-2.compute.internal   ebs.csi.aws.com
ip-10-0-55-192.eu-west-2.compute.internal   ebs.csi.aws.com
```

It still works, because Kubernetes has a feature called **CSI migration** that intercepts
requests naming the old provisioner and redirects them to the CSI driver.

> **"CSI migration" is the name of a Kubernetes feature, not a task anyone performs.**
> It is automatic and invisible. The first version of this document mentioned it without
> saying so, which reasonably read as a proposal to *do* a migration. There is no
> migration in our plan, and there never will be.

**It is not the default**, and that is recent: **AWS stopped adding the `default`
annotation at EKS 1.30.** So a Helm chart that omits `storageClassName` produces a PVC
that waits forever for a default class that does not exist — and nothing in the events
says so.

**It cannot grow.** `allowVolumeExpansion: false`.

**gp2 costs more and performs worse than gp3.** From the AWS Pricing API, `eu-west-2`:

| | USD / GB-month | Baseline IOPS |
|---|---|---|
| `gp2` | 0.1160 | 3 per GB — a 20Gi volume gets **60** |
| `gp3` | **0.0928** | **3000, flat, at any size** |

There is no size at which gp2 is the better choice.

### Decision: leave `gp2` alone, add `gp3`

*Decided 2026-09-01.*

**`gp2` stays, unmanaged and untouched.** It is an unused recipe: zero PVCs reference it,
so it has provisioned nothing and **costs nothing**. Deleting it would only invite EKS to
recreate it, and adopting it into Terraform would buy tidiness at the price of a resource
we do not want to own.

Recorded as a known unmanaged object rather than pretended away — the point of Property 7
is that unmanaged things are *accounted for*, not that they cannot exist.

**A new `gp3` StorageClass is created and marked default**, with:

| Setting | Value | Why |
|---|---|---|
| `provisioner` | `ebs.csi.aws.com` | The driver directly. No translation layer between the name and the behaviour |
| `type` | `gp3` | Cheaper and faster at every size |
| `allowVolumeExpansion` | `true` | A full disk becomes a resize, not a copy |
| `volumeBindingMode` | `WaitForFirstConsumer` | The volume is created in the zone the pod actually landed in |
| `encrypted` | `true` | Encryption at rest by default rather than by remembering |
| default annotation | yes | So a chart that omits the class works instead of hanging |

**No migration, in any environment.** Nothing exists to move: zero PVCs here, and prod has
no cluster yet. Every environment gets `gp3` from its first apply, and `gp2` sits unused
in each of them exactly as it does here.

## Sources

- [Use Kubernetes volume storage with Amazon EBS](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [Amazon EBS CSI migration frequently asked questions](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi-migration-faq.html)
- [Storage classes](https://docs.amazonaws.cn/en_us/eks/latest/userguide/storage-classes.html) — EKS adds `gp2`; the in-tree provisioner is deprecated
- [Change the default StorageClass](https://kubernetes.io/docs/tasks/administer-cluster/change-default-storage-class/)
- [In-tree Storage Plugin to CSI Migration — AWS (KEP 1487)](https://www.kubernetes.dev/resources/keps/1487/)
- EKS 1.30 dropping the `default` annotation on `gp2`: corroborated across several independent write-ups and AWS's 1.30 release notes
- Live cluster `eaf-dev` and the AWS Pricing API, both read 2026-09-01

*Content from AWS and Kubernetes documentation was rephrased for compliance with
licensing restrictions.*
