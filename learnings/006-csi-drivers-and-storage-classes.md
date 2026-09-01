# 006 — CSI drivers and StorageClasses

*Written 2026-09-01 against the live `eaf-dev` cluster, Kubernetes 1.36, EBS CSI driver
`v1.65.0-eksbuild.1`. Every observation below was read from that cluster.*

## The question

> what is this csi driver, can u explain me with diagram please. I am confusing, a
> automatic gp2 was created when we initialised the cluster

## Short answer

**CSI is the plug socket; a CSI driver is the plug.** Kubernetes has no idea what an EBS
volume is. It defines one standard interface — the Container Storage Interface — and AWS
ships a driver that speaks it on one side and the EC2 API on the other.

The `gp2` StorageClass you saw is created by EKS itself, not by us. It is **not** marked
default (AWS stopped doing that at EKS 1.30) and it names the **old** provisioner, which
is no longer registered on your nodes. So it is more misleading than useful.

## Start with the problem CSI solves

A pod wants a disk that survives being rescheduled. On AWS that means an EBS volume. But
Kubernetes runs on AWS, Azure, GCP, bare metal, and a laptop.

The original answer was to build every storage system into Kubernetes itself:

```
   ┌──────────────────────────────────────────────────────────────┐
   │  Kubernetes  ("in-tree")                                     │
   │                                                              │
   │   scheduler   kubelet   controller-manager                   │
   │                              │                               │
   │        ┌─────────────────────┼─────────────────────┐         │
   │        ▼                     ▼                     ▼         │
   │   ┌─────────┐          ┌──────────┐          ┌──────────┐    │
   │   │ AWS EBS │          │ GCE PD   │          │ Azure    │    │
   │   │  code   │          │  code    │          │ Disk code│    │
   │   └─────────┘          └──────────┘          └──────────┘    │
   │                                                              │
   │   ... and Cinder, vSphere, Ceph, Portworx, ...               │
   └──────────────────────────────────────────────────────────────┘
```

That is what "in-tree" means: **inside the Kubernetes source tree**. It had two problems
that eventually became unbearable.

A bug in the AWS storage code needed a **Kubernetes release** to fix. And every cluster
everywhere shipped code for every storage vendor, whether it used them or not — with
cloud credentials in the control plane to match.

## CSI: move the code out, define an interface

```
   ┌────────────────────────────────────────────────────────┐
   │  Kubernetes                                            │
   │                                                        │
   │   "I need a 20Gi volume for this pod"                  │
   │                     │                                  │
   │                     ▼                                  │
   │        ┌─────────────────────────────┐                 │
   │        │  Container Storage Interface│  ← a gRPC spec  │
   │        │  CreateVolume               │    Kubernetes   │
   │        │  ControllerPublishVolume    │    owns         │
   │        │  NodeStageVolume            │                 │
   │        │  NodePublishVolume          │                 │
   │        └─────────────────────────────┘                 │
   └─────────────────────┬──────────────────────────────────┘
                         │  implemented by
      ┌──────────────────┼──────────────────┐
      ▼                  ▼                  ▼
   ┌────────┐       ┌─────────┐       ┌──────────┐
   │ EBS CSI│       │ EFS CSI │       │ anyone   │
   │ driver │       │ driver  │       │ else's   │
   └────┬───┘       └─────────┘       └──────────┘
        │  talks to
        ▼
   ┌─────────────────┐
   │  EC2 API        │  CreateVolume, AttachVolume, ...
   └─────────────────┘
```

**Kubernetes owns the interface. AWS owns the driver.** The driver ships on its own
schedule, runs as ordinary pods in your cluster, and gets its own IAM identity — which is
why `aws-ebs-csi-driver` needed a Pod Identity association and `AmazonEBSCSIDriverPolicyV2`.

That is also why it is an **add-on**: it is software running in the cluster, not part of
the cluster.

## Where the pieces actually sit

```
   ┌─── control plane (AWS-managed) ──────────────────────────────┐
   │   API server · scheduler · controller-manager                │
   └──────────────────────────────┬───────────────────────────────┘
                                  │
   ┌─── your nodes ───────────────┼───────────────────────────────┐
   │                              ▼                               │
   │  ┌────────────────────────────────────────────────────────┐  │
   │  │  ebs-csi-controller  (Deployment, 2 replicas)          │  │
   │  │                                                        │  │
   │  │  Watches PVCs. Calls the EC2 API to CREATE and ATTACH  │  │
   │  │  volumes. This is the part that needs AWS credentials, │  │
   │  │  and the reason its ServiceAccount is                  │  │
   │  │  ebs-csi-controller-sa with a Pod Identity role.       │  │
   │  └────────────────────────────────────────────────────────┘  │
   │                                                              │
   │  ┌────────────────────────────────────────────────────────┐  │
   │  │  ebs-csi-node  (DaemonSet, one per node)               │  │
   │  │                                                        │  │
   │  │  Once a volume is attached to the instance, formats it │  │
   │  │  and mounts it into the pod. Needs NO AWS credentials  │  │
   │  │  — it is doing local filesystem work.                  │  │
   │  └────────────────────────────────────────────────────────┘  │
   └──────────────────────────────────────────────────────────────┘
```

Two halves, because the work is two different kinds: **one talks to AWS, the other talks
to the kernel.**

## The full journey of one volume

```
  ① You write a PersistentVolumeClaim
     ┌──────────────────────────────────┐
     │ kind: PersistentVolumeClaim      │
     │ spec:                            │
     │   storageClassName: gp3          │ ← or omitted, which means "use the default"
     │   resources: { requests:         │
     │       { storage: 20Gi } }        │
     └──────────────┬───────────────────┘
                    ▼
  ② The StorageClass says HOW to make it
     ┌──────────────────────────────────────────────────┐
     │ kind: StorageClass · name: gp3                   │
     │   provisioner: ebs.csi.aws.com   ← which driver  │
     │   parameters: { type: gp3 }      ← driver options│
     │   volumeBindingMode:                             │
     │     WaitForFirstConsumer         ← see below     │
     │   allowVolumeExpansion: true                     │
     └──────────────┬───────────────────────────────────┘
                    ▼
  ③ ebs-csi-controller sees it and calls EC2 CreateVolume
                    ▼
  ④ A real EBS volume exists, in ONE availability zone
                    ▼
  ⑤ Pod is scheduled to a node. Controller calls AttachVolume
                    ▼
  ⑥ ebs-csi-node formats and mounts it into the pod
                    ▼
  ⑦ /data inside the container is now an EBS volume
```

### `WaitForFirstConsumer` is the step people get wrong

An **EBS volume lives in exactly one availability zone**, and can only attach to an
instance in that same zone.

```
   Immediate binding                    WaitForFirstConsumer
   ─────────────────────────            ──────────────────────────
   volume created FIRST,                pod is scheduled FIRST,
   in some zone                         then the volume is created
        │                               in THAT pod's zone
        ▼                                    │
   scheduler must now find                    ▼
   a node in that zone                   always attachable
        │
        ▼
   if it cannot: pod Pending
   forever, and the message
   blames affinity, not storage
```

This is why `private_subnet_ids_by_az` exists as an output of the platform layer: anything
stateful has to agree with its volume about a zone.

## Now: the gp2 StorageClass you found

Read live from the cluster:

```
NAME   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE     ALLOWVOLUMEEXPANSION
gp2    kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer  false
```

**EKS created it, not us.** EKS has added a `gp2` StorageClass to every new cluster since
Kubernetes 1.11. Four things about it are worth knowing.

### 1. It names the OLD provisioner

`kubernetes.io/aws-ebs` is the in-tree plugin from the first diagram. The one whose code
lived inside Kubernetes. It has been deprecated since Kubernetes 1.17.

And on your nodes it is **not registered at all**. Read live:

```
NODE                                        DRIVERS
ip-10-0-32-154.eu-west-2.compute.internal   ebs.csi.aws.com
ip-10-0-55-192.eu-west-2.compute.internal   ebs.csi.aws.com
```

Only the CSI driver. So how could that StorageClass work? Through **CSI migration**:
Kubernetes intercepts requests naming the in-tree plugin and translates them to the CSI
driver.

```
   PVC: storageClassName: gp2
        │
        ▼
   provisioner kubernetes.io/aws-ebs
        │
        │   CSI migration translates
        ▼
   ebs.csi.aws.com  ← what actually runs
```

It works. But it means the *name* in your configuration and the code that *runs* are
different things, and understanding an incident requires knowing about the translation
layer.

### 2. It is NOT the default — and that is recent

There is no `storageclass.kubernetes.io/is-default-class` annotation on it. Verified.

**From EKS 1.30 onwards AWS stopped adding that annotation to new clusters.** Before 1.30
it was there. So a chart that worked on an older cluster and leaves `storageClassName`
unset will produce a PVC that sits `Pending` forever here — waiting for a default class
that does not exist.

That is a genuinely nasty failure: the PVC event says no storage class, the pod says it
is waiting for a volume, and nothing says "your cluster has no default".

### 3. It cannot grow

`allowVolumeExpansion: false`. Fill it and the only route is a new volume and a copy.

### 4. gp2 costs more than gp3 and performs worse

Priced from the AWS API for `eu-west-2` on 2026-09-01:

| | USD / GB-month | Baseline IOPS |
|---|---|---|
| `gp2` | 0.1160 | 3 per GB — a 20Gi volume gets 60 |
| `gp3` | **0.0928** | **3000, free, at any size** |

gp3 is about 20% cheaper *and* faster at small sizes. There is no size at which gp2 wins.

## What this means for the cluster-addons layer

Four decisions follow from the above:

1. **Create a `gp3` StorageClass** using `ebs.csi.aws.com` directly — no translation layer
   between the name and the behaviour.
2. **`allowVolumeExpansion: true`**, so a full disk is a resize rather than a migration.
3. **`WaitForFirstConsumer`**, so the volume is created in the zone the pod landed in.
4. **Mark it default, and un-default nothing** — because gp2 is already not default, there
   is nothing to take away. Worth knowing for later: since Kubernetes 1.26, if two classes
   are both marked default, **the most recently created one wins**. That is defined
   behaviour rather than random, but relying on creation order is a poor plan.

And a question worth deciding rather than drifting into: `gp2` is a live object in the
cluster that **no Terraform state owns**. That is exactly what Property 7 exists to
prevent. Either adopt it into the layer so it is tracked, or delete it. Leaving it is the
one option that guarantees the next person wonders where it came from.

## Sources

- [Use Kubernetes volume storage with Amazon EBS](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [Amazon EBS CSI migration frequently asked questions](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi-migration-faq.html) — responsibility moving from the in-tree provisioner to the driver
- [Storage classes](https://docs.amazonaws.cn/en_us/eks/latest/userguide/storage-classes.html) — the in-tree provisioner is deprecated
- [Change the default StorageClass](https://kubernetes.io/docs/tasks/administer-cluster/change-default-storage-class/) — Kubernetes' own guidance
- [In-tree Storage Plugin to CSI Migration — AWS (KEP 1487)](https://www.kubernetes.dev/resources/keps/1487/) — how translation works
- EKS 1.30 dropping the `default` annotation on `gp2`: corroborated by several independent write-ups; AWS's own release notes for 1.30 carry the same change
- Live cluster `eaf-dev` and the AWS Pricing API, both read 2026-09-01

*Content from AWS and Kubernetes documentation was rephrased for compliance with
licensing restrictions.*
