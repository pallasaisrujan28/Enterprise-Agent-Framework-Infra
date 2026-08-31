# 002 — Pod networking and the CNI

*Written 2026-08-31.*

## The question

> why do we need pod networking ? even pods are servers that needs t send
> information ?

And earlier, in the same thread:

> and do we need to enable vpc cni ? and also this cni is it there for normal
> kubernetes or it is an addon from aws ?

## Short answer

**A node is a server. A pod is not.** A pod is one application *sharing* a server
with many others, and that sharing is the problem — without pod networking, two
pods on one machine could not both listen on port 3000.

Kubernetes solves it by giving every pod its own IP address, and therefore its own
complete set of ports. It does not implement that itself: it defines a
specification, the **Container Network Interface**, and delegates to a plugin. CNI
is generic Kubernetes. **Amazon VPC CNI** is AWS's implementation of it.

## The problem is port collisions, not connectivity

The instinct in the question is reasonable — of course a pod needs to send
information, so what is there to solve? The answer is that the difficulty is not
*whether* it can talk, but *how many of them can share one machine's network*.

Kubernetes states it plainly:

> Kubernetes is all about sharing machines among applications. Typically, sharing
> machines requires ensuring that two applications do not try to use the same
> ports. Coordinating ports across multiple developers is very difficult to do at
> scale and exposes users to cluster-level issues outside of their control.

Look at what this platform runs:

```
firecrawl-playwright   :3000
langfuse-web           :3000     ← same port
firecrawl-api          :3002
neo4j                  :7687
redis                  :6379
agent                  :8080
```

### Without pod networking — the naive model

```
        ┌──────────────────────────────────────────────┐
        │  NODE   one IP: 10.0.11.46                   │
        │                                              │
        │   langfuse-web  wants :3000   ── binds OK    │
        │   playwright    wants :3000   ── FAILS       │
        │                    "address already in use"  │
        └──────────────────────────────────────────────┘
```

One process per host per port. To run both you would allocate unique host ports by
hand — playwright on 31000, langfuse on 31001 — and then every caller has to
discover which arbitrary port landed where, on which node, today.

Kubernetes considered exactly this and rejected it:

> Dynamic port allocation brings a lot of complications to the system — every
> application has to take ports as flags, the API servers have to know how to
> insert dynamic port numbers into configuration blocks, services have to know how
> to find each other, etc. Rather than deal with this, Kubernetes takes a
> different approach.

### With pod networking — IP per pod

```
        ┌──────────────────────────────────────────────────────┐
        │  NODE   10.0.11.46                                   │
        │                                                      │
        │   ┌────────────────────┐  ┌────────────────────┐      │
        │   │ pod langfuse-web   │  │ pod playwright     │      │
        │   │ IP 10.0.11.52      │  │ IP 10.0.11.53      │      │
        │   │ own netns          │  │ own netns          │      │
        │   │ :3000  ── binds OK │  │ :3000  ── binds OK │      │
        │   └────────────────────┘  └────────────────────┘      │
        │                                                      │
        │   Different IPs, so no collision. Each pod owns all   │
        │   65,535 of ITS ports.                                │
        └──────────────────────────────────────────────────────┘
```

Each pod gets its own **network namespace** — a Linux kernel feature giving it a
private network stack, its own interfaces, its own routing table, its own port
space.

This is why your configuration can say `langfuse-web.monitoring.svc.cluster.local:3000`
and mean it. The container genuinely owns port 3000. Nothing anywhere allocates
host ports.

## Four problems, and which one is the CNI's

Kubernetes separates them:

| # | Problem | Solved by |
|---|---|---|
| 1 | container ↔ container **inside one pod** | pods share a namespace — plain `localhost` |
| 2 | **pod ↔ pod** | **the CNI plugin** |
| 3 | pod ↔ Service | Services + cluster DNS + `kube-proxy` |
| 4 | outside world ↔ Service | Services, Ingress, load balancers |

Only #2 is the CNI. And Kubernetes does not implement it:

> The network model is implemented by the container runtime on each node. The most
> common container runtimes use Container Network Interface (CNI) plugins to
> manage their network and security capabilities. Many different CNI plugins exist
> from many different vendors.

So Kubernetes states the requirement — every pod has its own IP, and any pod can
reach any other pod on any node without NAT — and leaves *how* entirely open.

One detail worth remembering: a cluster needs **three non-overlapping IP ranges**.
Pods (assigned by the CNI), Services (by the API server), and Nodes (by the kubelet
or cloud controller).

## CNI is Kubernetes. VPC CNI is AWS

| | |
|---|---|
| **CNI** | A specification. Every Kubernetes cluster anywhere needs a plugin implementing it. Calico, Cilium, Flannel, Weave are alternatives |
| **Amazon VPC CNI** | AWS's implementation. Its distinguishing choice: pods get **real VPC IP addresses** instead of overlay addresses |

Real VPC addresses are genuinely valuable — a pod is directly reachable from
anywhere in the VPC, appears in flow logs like any other host, and security groups
apply in the ordinary way. No encapsulation, no separate overlay to debug.

The cost is that pod IPs consume subnet addresses and arrive through ENIs, which
have hard per-instance limits. That trade is the whole of
[004](004-prefix-delegation.md).

## Do we need to enable it? No — it is already on

Direct answer, from AWS:

> Amazon EKS automatically installs self-managed add-ons such as the Amazon VPC CNI
> plugin for Kubernetes, kube-proxy, and CoreDNS for every cluster.

You cannot have an EKS cluster without a CNI, and you do not switch it on. What you
choose is whether to *manage* it as an EKS add-on — see
[003](003-eks-addons.md), which is a different question from whether it exists.

## Why it matters here

The chain from this concept to the failures in this cluster is direct and complete:

```
pods need their own IPs
        ↓
VPC CNI takes them from your subnet
        ↓
subnet IPs reach a node through its ENIs
        ↓
ENIs have hard per-instance limits
        ↓
t3.medium = 3 ENIs × 6 IPs = 17 pods, full stop
        ↓
the 18th pod sat Pending with "Too many pods"
while CPU and memory were free
```

And it explains why `NetworkPluginNotReady` is fatal rather than cosmetic: with no
CNI, a scheduled pod never receives an IP, so it never starts. Which is in turn why
`vpc-cni` and `kube-proxy` must be in place **before** nodes join the cluster — the
add-on ordering the old `eks.tf` did not declare, and which the design flags as a
likely contributor to the recurring `ebs-csi` timeout.

## Sources

- [Cluster Networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/)
- [Amazon EKS add-ons](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html)

## Next

- [003](003-eks-addons.md) — what "add-on" means, and why we declare them anyway
- [004](004-prefix-delegation.md) — lifting the 17-pod ceiling
