# `modules/eks-node-group`

One managed node group. Called once per pool.

```hcl
module "node_group_default" {
  source = "../../modules/eks-node-group"

  org_prefix  = var.org_prefix
  environment = "dev"
  owner       = "platform-team"
  pool        = "default"

  cluster_name  = module.eks_cluster.name
  node_role_arn = module.eks_node_role.arn
  subnet_ids    = module.network.private_subnet_ids

  instance_types = ["m6i.large"]
  desired_size   = 2
  min_size       = 1
  max_size       = 4

  # vpc-cni, kube-proxy and the pod identity agent must be ACTIVE first.
  depends_on = [
    module.addon_vpc_cni,
    module.addon_kube_proxy,
    module.addon_pod_identity_agent,
  ]
}
```

## The `depends_on` is not optional

A node that joins a cluster with no CNI fails its health check with
`NodeCreationFailure: NetworkPluginNotReady` and stays `NotReady`. It does not fail fast
— the node group waits, then times out after 30 minutes.

This module cannot enforce it. Taking an add-on value as an input would work in that one
direction, but the reverse (add-ons depending on the node group, which `coredns` and the
EBS CSI driver need) would be a cycle. Ordering therefore lives at the call site, and
`modules/eks-addon`'s README has the full picture.

## The node role should be smaller than you think

It needs `AmazonEKSWorkerNodePolicy` and `AmazonEC2ContainerRegistryPullOnly`.

It should **not** carry `AmazonEKS_CNI_Policy`. That policy permits attaching and
detaching network interfaces and assigning IP addresses. On the node role, **every pod on
the node inherits it** through the instance metadata service — so a compromised container
can rewrite the node's networking. It belongs on the `vpc-cni` add-on's own Pod Identity
role.

`AmazonEC2ContainerRegistryPullOnly` supersedes `AmazonEC2ContainerRegistryReadOnly` for
this purpose: nodes need to pull images, not to enumerate repositories.

## Prefix delegation needs Nitro, and this module checks what it can

Prefix delegation is only supported on the Nitro system. On a non-Nitro instance it
**silently does nothing** — no error, the pod ceiling simply stays at the secondary-IP
limit.

`t2` is rejected outright, because it is the family most likely to be reached for by
habit and it is not Nitro. The general question cannot be answered from a type string,
so this is a guard rather than a proof: `t3`, `t4g`, `m5`, `m6i`, `m7g` and newer are all
Nitro.

Measured in `eu-west-2`, for reference:

| Instance | vCPU / GiB | Pods without PD | With PD |
|---|---|---|---|
| `t3.medium` | 2 / 4 | 17 | 110 (cap) |
| `t3.large` | 2 / 8 | 35 | 110 (cap) |
| `m6i.large` | 2 / 8 | 29 | 110 (cap) |
| `m6i.xlarge` | 4 / 16 | 58 | 110 (cap) |

Without prefix delegation an `m6i.large` runs out of pod slots at 29 while barely
touching 8 GiB of memory.

## Architecture mismatches are caught at plan

An ARM AMI on an x86 instance, or the reverse, fails at *launch* with a message about the
image rather than the mismatch — and the node group waits on instances that will never
register before timing out. Two preconditions catch both directions. AWS ARM families
carry a `g` in the size prefix: `m6g`, `m7g`, `c7g`, `t4g`.

Amazon Linux 2 (`AL2_*`) is end of life and rejected. The default is
`AL2023_x86_64_STANDARD`.

## `desired_size` is deliberately not ignored

The usual advice is `ignore_changes = [scaling_config[0].desired_size]` so an autoscaler
can move it without Terraform fighting back.

There is no autoscaler here yet. Ignoring it now would mean the number in the
configuration silently stops being the number that runs — and the design raises
`desired_size` deliberately as workloads land. Revisit when an autoscaler exists; until
then the configuration is the truth.

For the same reason, the Cluster Autoscaler discovery tags
(`k8s.io/cluster-autoscaler/enabled`) are **not** set. Advertising a pool to a controller
that is not running reads, to the next person, as though autoscaling were configured.

## Inputs

Required: `org_prefix`, `environment`, `owner`, `pool`, `cluster_name`, `node_role_arn`,
`subnet_ids`, `instance_types`, `desired_size`, `min_size`, `max_size`.

| Optional | Default | Notes |
|---|---|---|
| `capacity_type` | `"ON_DEMAND"` | `SPOT` is reclaimed with two minutes' notice |
| `ami_type` | `"AL2023_x86_64_STANDARD"` | Must match the instance architecture |
| `disk_size` | `50` | AWS defaults to 20 GiB, tight once images are cached |
| `kubernetes_version` | `null` | Follows the cluster |
| `labels` / `taints` | `{}` | Both are also outputs |
| `max_unavailable` | `1` | Slow and safe |
| `enable_node_repair` | `false` | Automatic replacement removes evidence while diagnosing |
| `create_timeout` | `"30m"` | |
| `extra_tags` | `{}` | Merged first; mandatory tags win |

## Outputs

`name`, `arn`, `status`, `autoscaling_group_names`, `labels`, `taints`, `tolerations`,
`inventory`.

**`labels` and `taints` are output as well as taken as input** so a later layer derives
its `nodeSelector` and tolerations from what the pool has, rather than restating them. A
toleration that no longer matches its taint gives you a pool nothing can schedule on, and
the symptom is `Pending` pods with a message nobody reads.

**`tolerations`** is the same information rendered as Kubernetes toleration objects.
Two spellings exist and they are not interchangeable — the EKS API uses `NO_SCHEDULE`, a
manifest uses `NoSchedule`. Translating here means the conversion happens once, in the
place that knows the taint. A valueless taint becomes `operator = "Exists"`, because
`Equal` with no value never matches.

**`inventory.interruptible`** flags a `SPOT` pool. A spot node holding anything with a
PVC is a recurring mistake: the node goes with two minutes' notice and the volume is
stranded in one availability zone.

## Tests

```sh
terraform -chdir=modules/eks-node-group test
```

18 tests, `command = plan`, no credentials — verified with every AWS environment variable
unset.
