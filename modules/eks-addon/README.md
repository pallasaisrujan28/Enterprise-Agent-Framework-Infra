# `modules/eks-addon`

One EKS add-on, plus its Pod Identity association if it needs AWS permissions.

## Ordering is the whole reason this is one add-on per call

The add-ons do **not** all belong at the same point in the graph:

```
   cluster
      │
      ├── vpc-cni  ·  kube-proxy  ·  eks-pod-identity-agent      BEFORE compute
      │        │
      │        ▼
      └──── node group
                │
                ▼
           coredns  ·  aws-ebs-csi-driver                        AFTER compute
```

Get the first direction wrong and nodes join a cluster with no CNI: they fail their
health check with `NodeCreationFailure: NetworkPluginNotReady` and sit `NotReady`.

Get the second wrong and the add-on's pods have nowhere to schedule, the add-on stays
`DEGRADED`, and Terraform waits until it times out.

A single module taking a map of every add-on could not express that split — the
after-compute ones would need a node-group value as an input, which makes the whole
module wait on the node group, which waits on the cluster. So each call site declares
its own `depends_on`, where both objects are visible.

```hcl
module "addon_vpc_cni" {
  source = "../../modules/eks-addon"

  org_prefix   = var.org_prefix
  environment  = "dev"
  owner        = "platform-team"
  cluster_name = module.eks_cluster.name

  addon_name    = "vpc-cni"
  addon_version = "v1.22.4-eksbuild.3"

  # Must be on from the first apply — see below.
  configuration_values = jsonencode({
    env = { ENABLE_PREFIX_DELEGATION = "true" }
  })

  pod_identity = {
    role_arn        = module.vpc_cni_role.arn
    service_account = "aws-node"
  }
}

module "node_group" {
  source = "../../modules/eks-node-group"
  # ...
  depends_on = [module.addon_vpc_cni, module.addon_kube_proxy, module.addon_pod_identity_agent]
}

module "addon_coredns" {
  source = "../../modules/eks-addon"
  # ...
  addon_name    = "coredns"
  addon_version = "v1.14.3-eksbuild.14"
  # coredns needs no AWS permissions, so no pod_identity.

  depends_on = [module.node_group]
}
```

## Prefix delegation cannot be retrofitted

`ENABLE_PREFIX_DELEGATION` affects how the CNI allocates addresses **to an instance at
launch**. Turning it on later does not change nodes already running — it requires
replacing them. So it goes on from the first apply, and `inventory.prefix_delegation_on`
reports it.

Without it an `m6i.large` tops out at 29 pods, against 8 GiB of memory it has barely
touched. With it, the ceiling is the Kubernetes-recommended 110.

Prefix delegation also needs **Nitro** instances and **contiguous `/28` blocks** in the
subnet — which is why `modules/network` defaults to `/20` subnets rather than `/24`.

## `addon_version` is required, with no default

Omitting it installs whatever AWS considers default for the cluster's Kubernetes version
*at apply time*, and that changes as AWS ships builds. Two applies from identical
configuration would then install different software, and the difference would read as
unexplained drift rather than as a decision.

Find the current default:

```sh
aws eks describe-addon-versions --kubernetes-version 1.36 --addon-name vpc-cni \
  --query 'addons[0].addonVersions[?compatibilities[0].defaultVersion==`true`].addonVersion'
```

Note the leading `v`. Without it the API reports the version as not found, which reads
as though the add-on were unavailable.

## Pod Identity, and why the pairing is a single object

`pod_identity` is one object with both `role_arn` and `service_account` required, rather
than two separate arguments. That makes "a role with no service account" unrepresentable
— and it is worth making impossible, because it creates no association, so the add-on
falls back to the **node role's** permissions and appears to work with the wrong
identity, silently.

Ask AWS which add-ons need this rather than guessing:

```sh
aws eks describe-addon-configuration --addon-name vpc-cni --addon-version V
```

| Add-on | Service account | Policy AWS recommends |
|---|---|---|
| `vpc-cni` | `aws-node` | `AmazonEKS_CNI_Policy` |
| `aws-ebs-csi-driver` | `ebs-csi-controller-sa` | `AmazonEBSCSIDriverPolicyV2` |
| `coredns` | — | none needed |
| `kube-proxy` | — | none needed |

`service_account_role_arn` is the IRSA form and is deliberately unused. See
`learnings/005-irsa-and-pod-identity.md`.

## Conflict resolution defaults to `OVERWRITE`

EKS pre-installs self-managed `vpc-cni`, `kube-proxy` and `coredns` on every new
cluster, so **taking over something already running is the normal case**. The provider
default (`NONE`) fails with a conflict instead.

`OVERWRITE` on update too, so field-level edits made outside Terraform are discarded on
the next apply. An add-on patched by hand during an incident is exactly the untracked
change this repository exists to stop.

`preserve` defaults to `false`: leaving a running DaemonSet that nothing manages is how
a cluster stops matching any configuration.

## Inputs

Required: `org_prefix`, `environment`, `owner`, `cluster_name`, `addon_name`,
`addon_version`.

| Optional | Default | Notes |
|---|---|---|
| `configuration_values` | `null` | JSON string; use `jsonencode()` |
| `pod_identity` | `null` | Object with both fields, or absent |
| `resolve_conflicts_on_create` | `"OVERWRITE"` | |
| `resolve_conflicts_on_update` | `"OVERWRITE"` | |
| `preserve` | `false` | |
| `create_timeout` / `update_timeout` | `"20m"` | Generous: a stuck add-on waits rather than failing fast |
| `extra_tags` | `{}` | Merged first; mandatory tags win |

## Outputs

`addon_name`, `addon_version`, `arn`, `id`, `inventory`.

**`id`** is a useful `depends_on` target: an add-on that must exist before something
else works — the CNI before nodes join — is expressed by depending on it rather than by
hoping apply order is right.

**`inventory.identity`** states plainly how the add-on gets credentials, because the
alternative (falling back to the node role) looks identical from outside.

## Tests

```sh
terraform -chdir=modules/eks-addon test
```

10 tests, `command = plan`, no credentials.
