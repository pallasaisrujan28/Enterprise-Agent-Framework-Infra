# 001 — The EKS ecosystem, end to end

*Written 2026-08-31. Applies to EKS with managed node groups and the Amazon VPC
CNI. Numbers measured in `EAF-DEV` (718438899462), `eu-west-2`.*

## The question

> can u explain the aws eks cluster and nodes
>
> and also it would be helpful if you explain all these concepts by drawing
> diagrams and boxes of eks cluster eco system . entire how nodes like vpc eni
> kubect server all these things

## Short answer

A Kubernetes cluster has a **brain** and **muscle**. EKS splits ownership between
them: AWS runs the brain (the control plane) on machines you never see, and you run
the muscle (nodes) as ordinary EC2 instances in your own VPC. Almost every quirk in
this repository comes from that split — two IAM roles, two failure domains, and the
fact that pod IP addresses come out of *your* subnets.

## The whole picture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ AWS ACCOUNT — EAF-DEV  718438899462                              eu-west-2      │
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │ AWS-MANAGED  ·  you pay for it, you never see the machines                │  │
│  │                                                                           │  │
│  │   EKS CONTROL PLANE          cluster "eaf-dev",  Kubernetes 1.36          │  │
│  │   ┌──────────────┐ ┌───────────┐ ┌────────────────────┐ ┌──────────────┐  │  │
│  │   │  API server  │ │ scheduler │ │ controller-manager │ │     etcd     │  │  │
│  │   │  (the door)  │ │  (places  │ │  (keeps reality    │ │ (the only    │  │  │
│  │   │              │ │   pods)   │ │   matching desire) │ │  source of   │  │  │
│  │   │              │ │           │ │                    │ │  truth)      │  │  │
│  │   └──────┬───────┘ └───────────┘ └────────────────────┘ └──────────────┘  │  │
│  └──────────┼────────────────────────────────────────────────────────────────┘  │
│             │  HTTPS. Every instruction and every status report crosses here.    │
│             │  Reachable publicly today; design Step 10 makes it VPC-only.       │
│  ┌──────────┼────────────────────────────────────────────────────────────────┐  │
│  │ YOUR VPC │ 10.0.0.0/16                                                    │  │
│  │          │                                                                │  │
│  │  PUBLIC SUBNETS  ── internet gateway, NAT gateway                         │  │
│  │  ┌──────────────────────────────────────────────────────────────────┐     │  │
│  │  │  NAT  →  lets private nodes reach the internet outbound only      │     │  │
│  │  └──────────────────────────────────────────────────────────────────┘     │  │
│  │                                                                           │  │
│  │  PRIVATE SUBNETS  ── every node lives here, no inbound from internet      │  │
│  │  ┌─────────────────────────────────┐  ┌─────────────────────────────────┐ │  │
│  │  │ NODE  ip-10-0-11-46             │  │ NODE  ip-10-0-12-89             │ │  │
│  │  │ EC2 instance · m6i.large        │  │ EC2 instance · m6i.large        │ │  │
│  │  │                                 │  │                                 │ │  │
│  │  │  kubelet ────────────┐          │  │  kubelet ────────────┐          │ │  │
│  │  │   "what should I run?"│─────────┼──┼──────────────────────┘          │ │  │
│  │  │   "here is my status" │  to API │  │                                 │ │  │
│  │  │                       │  server │  │                                 │ │  │
│  │  │  kube-proxy   (Service routing) │  │  kube-proxy                     │ │  │
│  │  │  aws-node     (the CNI)         │  │  aws-node                       │ │  │
│  │  │                                 │  │                                 │ │  │
│  │  │  ┌── ENI 1 ── 10.0.11.46 ─────┐ │  │  ┌── ENI 1 ── 10.0.12.89 ────┐  │ │  │
│  │  │  │ pod  agent      10.0.11.52 │ │  │  │ pod  neo4j     10.0.12.95 │  │ │  │
│  │  │  │ pod  firecrawl  10.0.11.53 │ │  │  │ pod  langfuse  10.0.12.96 │  │ │  │
│  │  │  └────────────────────────────┘ │  │  └───────────────────────────┘  │ │  │
│  │  │  ┌── ENI 2 ── (more pod IPs) ──┐ │  │                                 │ │  │
│  │  │  └────────────────────────────┘ │  │  Pod IPs are REAL VPC addresses. │ │  │
│  │  └─────────────────────────────────┘  └─────────────────────────────────┘ │  │
│  └───────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## The two halves, and why the split matters

### Control plane — AWS runs it

| Component | Job |
|---|---|
| **API server** | The only way in. `kubectl`, Terraform's `kubernetes` provider, and every kubelet all talk to this |
| **scheduler** | Decides which node each new pod goes on, based on requests, taints and affinity |
| **controller-manager** | Notices when reality differs from what was asked for, and acts. "Deployment wants 3 replicas, 2 exist" → create one |
| **etcd** | Stores everything. The cluster's memory |

Created by `aws_eks_cluster`. You get an HTTPS endpoint and a CA certificate, and
that is the entire surface. Roughly $0.10/hour.

### Nodes — you run them

Ordinary EC2 instances. Yours, in your VPC, on your bill. Each runs:

| Component | Job |
|---|---|
| **kubelet** | Asks the API server "what should be running on me?", starts and stops containers, reports health back |
| **container runtime** | Actually runs the containers (containerd) |
| **kube-proxy** | Makes Service addresses work — routes a Service IP to a real pod IP |
| **aws-node** | The CNI. Gives each pod an IP. See [002](002-pod-networking-and-cni.md) |

A **managed node group** (`aws_eks_node_group`) is AWS operating the launch template
and autoscaling group for you: you declare instance type and min/max/desired, and
EKS handles replacement and draining.

### Why two IAM roles, and why they cannot be one

AWS documents that you cannot reuse the cluster role for nodes. The reason is
visible once the split is clear — they are assumed by different principals:

```
cluster role   trusted by  eks.amazonaws.com   →  the CONTROL PLANE acts in your account
node role      trusted by  ec2.amazonaws.com   →  each WORKER acts on its own behalf
```

The control plane needs to describe instances and subnets, tag things, and create
load balancers for Services. A node needs to pull images from ECR and register
itself. Different actors, different needs.

## What actually happens when you deploy something

```
   you                     control plane                        node
    │                            │                               │
    │ kubectl apply / terraform  │                               │
    ├───────────────────────────►│ API server validates,          │
    │                            │ writes desired state to etcd   │
    │                            │                               │
    │                            │ scheduler picks a node        │
    │                            │ with room                     │
    │                            │                               │
    │                            │◄──────────────────────────────┤ kubelet polls:
    │                            │  "run pod X on you"           │ anything for me?
    │                            │                               │
    │                            │                               ├─► CNI: assign an IP
    │                            │                               │   from the subnet
    │                            │                               ├─► pull image from ECR
    │                            │                               ├─► start container
    │                            │                               │
    │                            │◄──────────────────────────────┤ status: Running
    │◄───────────────────────────┤                               │
```

Two things to take from this.

**Nothing pushes to a node.** The kubelet pulls. So a node needs outbound reach to
the API server, which is why nodes sit in private subnets behind a NAT gateway.

**The scheduler can refuse.** If no node has room, the pod sits `Pending`
indefinitely. It is not an error and nothing retries into existence — the pod waits
for capacity that may never arrive. This is what `Too many pods`,
`Insufficient cpu` and `Insufficient memory` mean.

## ENIs, and where pod IPs come from

This is the piece that surprises people, and it is the root of the capacity
problem in this repository.

**Amazon VPC CNI gives every pod a real IP address from your VPC subnet.** Not an
address on a private overlay — a genuine VPC address, routable, visible in flow
logs, addressable from anywhere in the VPC.

Those addresses reach a node through **Elastic Network Interfaces**. An ENI is a
virtual network card attached to an EC2 instance. Each instance type caps how many
ENIs it can have, and how many IPv4 addresses each ENI can hold. One address per
ENI belongs to the node; the rest are available to pods.

```
maxPods = ENIs × (IPs per ENI − 1) + 2
```

Measured from the EC2 API on 2026-08-31:

| instance | vCPU | RAM | ENIs | IPs/ENI | **maxPods** |
|---|---|---|---|---|---|
| `t3.medium` | 2 | 4 GiB | 3 | 6 | **17** |
| `t3.large` | 2 | 8 GiB | 3 | 12 | 35 |
| `m6i.large` | 2 | 8 GiB | 3 | 10 | 29 |
| `m6i.xlarge` | 4 | 16 GiB | 4 | 15 | 58 |

**This is where the 17 came from.** Not a setting, not a guess — arithmetic from
the instance type. A `t3.medium` cannot run an 18th pod regardless of idle CPU and
memory. [004](004-prefix-delegation.md) is how that limit is lifted.

## Where `kubectl` fits, and why it needed a token

`kubectl` is only an HTTPS client for the API server. It needs three things, all of
which appear in `provider.tf`:

```
host                    https://XXXX.gr7.eu-west-2.eks.amazonaws.com
cluster_ca_certificate  proves the server is really your cluster
token                   proves who YOU are
```

EKS authenticates with **AWS IAM**, not Kubernetes users. So `aws eks get-token`
signs an STS request with your AWS credentials and hands the result to the API
server, which verifies it and maps it to Kubernetes permissions via an **access
entry**.

Two consequences that cost this project real time:

**IAM identity must be right before the Kubernetes call.** An `exec` block calling
`aws eks get-token` mints a token for whoever the *runner* is. When the pipeline
authenticated as a management-account role but the resources lived in EAF-DEV, the
token was for the wrong identity and the API server refused it. That is why the
`--role-arn` argument exists in those exec blocks.

**Being allowed by IAM is not being allowed by Kubernetes.** They are separate
grants. An access entry maps an IAM principal to Kubernetes permissions; without
one, valid AWS credentials still get you nothing from the API server.

## Failure modes, and which half is at fault

| Symptom | Which half | Meaning |
|---|---|---|
| `Pending` + `Too many pods` | node | ENI IP limit reached. See [004](004-prefix-delegation.md) |
| `Pending` + `Insufficient cpu/memory` | node | No node has enough free capacity |
| `Pending` + `untolerated taint` | scheduling | Capacity exists but this pod is not permitted on it |
| `ImagePullBackOff` | node | Image does not exist, or the node role cannot pull it |
| `CrashLoopBackOff` | your container | It started and exited, repeatedly. Application fault |
| `NetworkPluginNotReady` | node | No CNI. Nothing can get an IP, so nothing starts |
| `Unauthorized` from `kubectl` | control plane | IAM identity has no access entry, or the token was minted for the wrong identity |

## Why it matters here

Every one of these appeared in this cluster at once: 12 `Pending`, 6
`ImagePullBackOff`, 1 `CrashLoopBackOff`, on a `t3.medium` at 16 of 17 pod slots
while a `t3.large` sat at 4 of 35 behind a taint nothing tolerated.

The design's three-layer split follows the ownership boundary drawn above. **L1**
owns everything AWS — VPC, subnets, cluster, node groups, ENI-bearing things. **L2**
and **L3** own Kubernetes objects and therefore need the API server to already
exist. That is not a stylistic choice; it is why configuring the `kubernetes`
provider from a cluster in the same apply cannot work (RC2).

## Sources

- [Amazon EKS cluster IAM role](https://docs.aws.amazon.com/eks/latest/userguide/cluster-iam-role.html)
- [Amazon EKS node IAM role](https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html)
- [Cluster Networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/)
- [Assign more IP addresses to Amazon EKS nodes with prefixes](https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html)
- ENI and IP limits: `aws ec2 describe-instance-types`, measured 2026-08-31

## Next

- [002](002-pod-networking-and-cni.md) — why pods need their own IPs at all
- [003](003-eks-addons.md) — what the `vpc-cni`, `kube-proxy` and `coredns` add-ons are
- Design `RC2` — why the provider split follows the ownership boundary
