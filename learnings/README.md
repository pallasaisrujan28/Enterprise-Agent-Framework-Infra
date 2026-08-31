# Learnings

Concepts explained on demand, kept because an explanation you can return to is
worth more than one you had once.

## How this works

Each file records **one question and its answer**. The question is preserved as
asked, not tidied up, because the phrasing is often the most useful part — it says
where the gap actually was.

Every file follows the same shape:

| Section | Purpose |
|---|---|
| **The question** | As asked |
| **Short answer** | Two or three sentences. Enough to act on |
| **The explanation** | Diagrams first where they help, then detail |
| **Why it matters here** | Tied to this repository, with real numbers |
| **Sources** | Links, so it can be re-verified when it drifts |

Two rules for what goes in these files.

**Verified, not remembered.** Anything factual is checked against vendor
documentation or the live AWS API at the time of writing, and the source is linked.
Where something was *measured* in this account, the number and the date are given.
Where I was wrong earlier in a conversation, the correction stays in the file rather
than being quietly edited out — a corrected misconception is more instructive than
a clean answer.

**Documentation drifts.** Every file carries the date it was written and the
versions it applies to. Treat anything older than a few months as a starting point
for re-checking, not as truth.

## Index

| # | Topic | Answers |
|---|---|---|
| [001](001-eks-ecosystem.md) | The EKS ecosystem, end to end | What a cluster and nodes actually are, how VPC / subnet / ENI / API server / kubelet / pod fit together, and what `kubectl` does |
| [002](002-pod-networking-and-cni.md) | Pod networking and the CNI | Why pods need networking at all when they are "just servers", what a CNI is, whether it is a Kubernetes thing or an AWS thing |
| [003](003-eks-addons.md) | Add-ons | What "add-on" means, whether the VPC CNI needs enabling, why we declare add-ons in Terraform when EKS installs them anyway |
| [004](004-prefix-delegation.md) | Prefix delegation | Why a `t3.medium` stops at 17 pods with CPU and memory to spare, and what changes that |

## Related, and deliberately not duplicated here

Design decisions and their reasoning live in
`.kiro/specs/eks-platform-restructure/design.md`, which has its own sections on
IAM behaviour (`IAM Reference`), role conventions (`IAM Role Design`) and the seven
root causes. These files explain *concepts*; the design explains *choices made in
this repository*. Where a concept underpins a decision, the file says which design
section to read next.
