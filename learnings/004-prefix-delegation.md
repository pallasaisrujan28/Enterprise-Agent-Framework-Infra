# 004 — Prefix delegation

*Written 2026-08-31. Instance limits measured from the EC2 API in `eu-west-2` on
that date. Linux nodes, Amazon VPC CNI ≥ 1.9.0.*

## The question

> can u explain me bit clear what is prefix delegation

## Short answer

Pod IPs come from your VPC subnet and reach a node through its network interfaces,
which have hard per-instance limits. A `t3.medium` tops out at **17 pods** no matter
how much CPU and memory sit idle.

Prefix delegation makes the CNI request a **`/28` block of 16 addresses** per
interface slot instead of one address at a time. `t3.medium` goes from 17 pod slots
to 110 — Kubernetes' default per-node cap — so CPU and memory become the binding
constraint instead of IP addresses.

It must be decided **before nodes exist**. Switching later means building new node
groups, not changing a setting.

## The limit, and where it comes from

```
maxPods = ENIs × (IPs per ENI − 1) + 2
```

One address per interface belongs to the node; the rest go to pods.

Measured, not remembered:

| instance | vCPU | RAM | ENIs | IPs/ENI | maxPods | with prefix | capped at |
|---|---|---|---|---|---|---|---|
| `t3.medium` | 2 | 4 GiB | 3 | 6 | **17** | 242 | **110** |
| `t3.large` | 2 | 8 GiB | 3 | 12 | 35 | 530 | 110 |
| `m6i.large` | 2 | 8 GiB | 3 | 10 | 29 | 434 | 110 |
| `m6i.xlarge` | 4 | 16 GiB | 4 | 15 | 58 | 898 | 110 |

`3 × (6−1) + 2 = 17`. That is the number from the design's Right-Sizing table. It
was never a configuration choice.

## What changes

```
WITHOUT prefix delegation — one address per slot

   ENI 1  ┌──────┬──────┬──────┬──────┬──────┬──────┐
          │ node │ pod  │ pod  │ pod  │ pod  │ pod  │     5 pods
          │ .46  │ .52  │ .53  │ .54  │ .55  │ .56  │
          └──────┴──────┴──────┴──────┴──────┴──────┘
   × 3 ENIs  =  15 pod slots  (+2)  =  17


WITH prefix delegation — a /28 block per slot

   ENI 1  ┌──────┬─────────────┬─────────────┬─────────────┐
          │ node │  /28 block  │  /28 block  │  /28 block  │  ...
          │ .46  │  16 addrs   │  16 addrs   │  16 addrs   │
          └──────┴─────────────┴─────────────┴─────────────┘
                       16 pods       16 pods       16 pods
   × 3 ENIs  =  240 pod slots  →  capped at 110 by Kubernetes
```

Same interfaces, same slots. Each slot now carries 16 addresses instead of 1.

There is a second benefit AWS mentions: far fewer EC2 API calls, because the CNI
takes 16 addresses in one request rather than making 16 requests. That shows up as
faster pod and node startup, and it matters more as a cluster grows:

> If you don't configure your cluster for IP prefix assignment, your cluster must
> make more Amazon EC2 application programming interface (API) calls to configure
> network interfaces and IP addresses necessary for Pod connectivity. As clusters
> grow to larger sizes, the frequency of these API calls can lead to longer Pod and
> instance launch times.

## Why the timing is the real decision

This is the part that makes it worth deciding now rather than later. AWS:

> When transitioning from assigning IP addresses to assigning IP prefixes, we
> recommend that you create new node groups to increase the number of available IP
> addresses, rather than doing a rolling replacement of existing nodes. Running Pods
> on a node that has both IP addresses and prefixes assigned can lead to
> inconsistency in the advertised IP address capacity, impacting the future
> workloads on the node.

So enabling it later is **not a setting change**. It is: build new node groups,
migrate workloads, retire the old ones. On an empty cluster it costs nothing. After
Langfuse and Neo4j have attached volumes, it is a migration with data in it.

A second one-way door:

> After you configure the add-on to assign prefixes to network interfaces, you
> can't downgrade your Amazon VPC CNI plugin for Kubernetes add-on to a version
> lower than 1.9.0 (or 1.10.1) without removing all nodes in all node groups.

Not a practical concern going forward, but it is irreversible without replacing
every node, so it belongs in a comment next to the setting.

## The cost, stated honestly

**Subnet address consumption.** Each node reserves `/28` blocks whether or not the
pods exist, and prefixes need *contiguous* address space. On a small subnet you can
exhaust addresses or fail to find a contiguous block.

For this platform: the VPC is `10.0.0.0/16` across 6 subnets, roughly 4,000
addresses each, for a cluster expected to run around 27 pods. Not remotely a
constraint. On a `/24` subnet it would need thinking about.

**Linux only**, which is all this platform runs.

The default cap of 110 pods per node can be raised, but at that point CPU and memory
are the real limits — which is the point.

## Why it matters here

The cluster showed `Too many pods` on a node with idle CPU and memory, while a
larger node sat at 4 of 35 slots behind a taint nothing tolerated. Two separate
faults, and prefix delegation removes one of them permanently and for free.

The design's Right-Sizing recommendation puts it first of three changes, ahead of
resizing instances or removing the taint, because it is the cheapest and it
eliminates one of the scheduler's three distinct complaints outright.

L1 sets `ENABLE_PREFIX_DELEGATION=true` in the `vpc-cni` add-on configuration from
the first apply, with the one-way-door note recorded at the setting.

## Sources

- [Assign more IP addresses to Amazon EKS nodes with prefixes](https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html)
- [EKS best practices: prefix mode for Linux](https://docs.aws.amazon.com/eks/latest/best-practices/prefix-mode-linux.html)
- Instance limits: `aws ec2 describe-instance-types`, 2026-08-31

## Next

- [002](002-pod-networking-and-cni.md) — why pods have IPs at all
- [003](003-eks-addons.md) — how the setting reaches the CNI
