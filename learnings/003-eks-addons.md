# 003 — Add-ons

*Written 2026-08-31. Add-on versions are the AWS defaults for Kubernetes 1.36 in
`eu-west-2`, queried 2026-08-31.*

## The question

> and also u have been using term called addon what does it mean ?
>
> do we need to enable vpc cni ?

## Short answer

An add-on is the plumbing your application assumes — networking, storage drivers,
DNS — rather than your application itself. The word does double duty: **lowercase
add-on** is the software, **capital-A EKS Add-on** is AWS's mechanism for managing
its version and configuration through the EKS API.

You do not enable the VPC CNI. EKS installs it on every cluster automatically.
Declaring `aws_eks_addon` **takes over management** of something already running.

## What AWS means by add-on

> An add-on is software that provides supporting operational capabilities to
> Kubernetes applications, but is not specific to the application. This includes
> software like observability agents or Kubernetes drivers that allow the cluster
> to interact with underlying AWS resources for networking, compute, and storage.

Not your workload. The layer your workload takes for granted.

## The two meanings, kept apart

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  lowercase "add-on"  ·  the SOFTWARE                                  │
   │                                                                      │
   │    CoreDNS       a Kubernetes project — cluster DNS                  │
   │    kube-proxy    a Kubernetes component — Service routing            │
   │    VPC CNI       an AWS open-source project — pod IPs                │
   │    EBS CSI       an AWS driver — turns PVCs into EBS volumes          │
   └──────────────────────────────────────────────────────────────────────┘
                                    │
                        the same software, but managed
                                    ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │  capital-A "EKS Add-on"  ·  the MANAGEMENT MECHANISM                 │
   │                                                                      │
   │    AWS versions it, patches it, validates it against your k8s         │
   │    version, and lets you configure it through the EKS API rather      │
   │    than by editing manifests inside the cluster.                      │
   │                                                                      │
   │    Terraform: resource "aws_eks_addon"                               │
   └──────────────────────────────────────────────────────────────────────┘
```

Three support tiers:

| Tier | Built by | Supported by |
|---|---|---|
| **AWS add-ons** | AWS | AWS, fully. VPC CNI, EBS CSI, CoreDNS, kube-proxy |
| **Marketplace add-ons** | Partner | The partner |
| **Community add-ons** | AWS packages from source | Open source community. AWS validates version compatibility only |

## So do we need to enable the VPC CNI? No

> Amazon EKS automatically installs self-managed add-ons such as the Amazon VPC CNI
> plugin for Kubernetes, kube-proxy, and CoreDNS for every cluster.

Every cluster gets all three, unasked. There is no such thing as an EKS cluster
without a CNI.

And specifically for Terraform:

> If you create your cluster using `eksctl` without a config file, `eksctl`
> installs kube-proxy, Amazon VPC CNI plugin for Kubernetes, CoreDNS, and
> metrics-server as Amazon EKS add-ons starting with version 0.184.0. For earlier
> versions of `eksctl`, **or if you use any other tool**, the self-managed
> kube-proxy, Amazon VPC CNI plugin for Kubernetes, and CoreDNS add-ons install
> instead.

"Any other tool" includes Terraform. So `aws_eks_cluster` produces a cluster with
**self-managed** copies already running.

```
   aws_eks_cluster created
            │
            ├──►  self-managed vpc-cni      already running
            ├──►  self-managed kube-proxy   already running
            └──►  self-managed coredns      already running
                          │
       aws_eks_addon does NOT install these.
       It TAKES OVER their management.
                          │
                          ▼
       which is why the old code needed:
           resolve_conflicts_on_create = "OVERWRITE"
       — "yes, adopt the copy that is already there"
```

That flag in the old `eks.tf` was not a workaround for a bug. It was the correct
answer to a question nobody had written down.

## Then why declare them at all — three reasons

### 1. Version pinning and patches

Self-managed means whatever shipped with the cluster, upgraded by you, by hand,
forever. As an EKS add-on you pin a version and AWS supplies security patches.

Current AWS defaults for Kubernetes 1.36 in `eu-west-2`:

```
vpc-cni             v1.22.4-eksbuild.3
kube-proxy          v1.36.0-eksbuild.17
coredns             v1.14.3-eksbuild.14
aws-ebs-csi-driver  v1.65.0-eksbuild.1
```

### 2. Configuration through the API instead of in the cluster

`ENABLE_PREFIX_DELEGATION` ([004](004-prefix-delegation.md)) is set through the
add-on's configuration values. Self-managed, you would be patching a DaemonSet
inside the cluster — a change with no plan, no review and no record. That is
exactly the class of out-of-band mutation the design's RC4 is about.

### 3. IRSA attachment — the security one

`aws_eks_addon` takes `service_account_role_arn`. This lets the CNI hold **its own
IAM role** for `kube-system:aws-node`.

Without it, `AmazonEKS_CNI_Policy` has to sit on the **node** role — and then every
pod on that node can reach CNI permissions through the instance metadata service,
not just the CNI. AWS says so directly:

> If the `AmazonEKS_CNI_Policy` policy is attached to the role, we recommend
> removing it and attaching it to an IAM role that is mapped to the `aws-node`
> Kubernetes service account instead.

The old `eks.tf` attached it to the node role. The add-on mechanism is what makes
fixing that clean.

## Ordering, and why it is not arbitrary

Two of these configure the network. Two of them *run as pods* and therefore need a
node to exist.

```
   ┌──────────────────┐
   │ vpc-cni          │  installed ON THE CLUSTER — a node without a CNI
   │ kube-proxy       │  fails its health check: NetworkPluginNotReady
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │ node group       │  nodes join and become Ready
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │ coredns          │  these RUN AS PODS, so they need a node
   │ aws-ebs-csi      │  to schedule onto
   └──────────────────┘
```

The old `eks.tf` gave `coredns` a `depends_on` the node group but left `vpc_cni` and
`kube_proxy` with no ordering at all. The design names this as a likely contributor
to the repeated `aws-ebs-csi-driver` stuck in `CREATING` past its 20-minute timeout.

## One useful thing to know

Add-ons install into a default namespace, which you can query rather than guess:

```sh
aws eks describe-addon-versions --addon-name vpc-cni --query 'addons[].defaultNamespace'
# ["kube-system"]
```

A custom namespace can be set at creation, but changing it later requires removing
and recreating the add-on.

## Why it matters here

Three concrete decisions in L1 come from this:

- All four add-ons are declared as `aws_eks_addon` with pinned versions, so a CI
  runner and a laptop agree
- `vpc-cni` gets `service_account_role_arn` pointing at a new IRSA role, which takes
  `AmazonEKS_CNI_Policy` off the node role
- Ordering is declared explicitly: `vpc-cni`, `kube-proxy` → node group → `coredns`,
  `aws-ebs-csi-driver`

## Sources

- [Amazon EKS add-ons](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html)
- [Amazon EKS node IAM role](https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html)
- Versions: `aws eks describe-addon-versions --kubernetes-version 1.36`, 2026-08-31

## Next

- [004](004-prefix-delegation.md) — the add-on setting that lifts the pod ceiling
