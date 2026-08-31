# `modules/eks-cluster`

The EKS control plane, and who may reach it.

```hcl
module "eks_cluster" {
  source = "../../modules/eks-cluster"

  org_prefix         = var.org_prefix
  environment        = "dev"
  owner              = "platform-team"
  kubernetes_version = "1.36"

  cluster_role_arn = module.eks_cluster_role.arn
  subnet_ids       = module.network.private_subnet_ids

  access_entries = {
    deployer = {
      principal_arn = var.deployer_role_arn
      policies = [{
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        scope_type = "cluster"
      }]
    }
  }
}
```

## What this module does not do

| Not here | Where instead | Why |
|---|---|---|
| IAM roles | `modules/iam-role` | One creation path for every role in the repository. Pass ARNs in |
| Add-ons | `modules/eks-addon`, once per add-on | Ordering relative to the node group cannot be expressed from in here — see below |
| Node groups | `modules/eks-node-group` | |
| OIDC provider | nowhere | The platform uses Pod Identity, which needs none |

### Why add-ons cannot live in this module

CoreDNS and the EBS CSI driver must be installed **after** a node group exists. Their
pods cannot schedule on an empty cluster, the add-on stays `DEGRADED`, and Terraform
waits until it times out.

Expressing that from here would mean accepting a node-group value as an input to create
the dependency. But **a module input makes the whole module wait** — so the cluster
would depend on the node group, which depends on the cluster. A cycle.

The same shape as RC2: a value needed before the resource that produces it can exist.
So ordering lives at the call site, where both objects are visible.

## Three settings that are easy to get wrong once and forever

### `authentication_mode` is `API`, and not configurable

AWS defaults this to `CONFIG_MAP` for clusters created through the API, SDKs or
CloudFormation — which is Terraform's path. `CONFIG_MAP` is the `aws-auth` ConfigMap,
which **AWS has deprecated** in favour of the Cluster Access Management API.

Not offered as a choice, for two reasons. The migration is **one-way**: once a cluster
is on `API` you cannot return to `CONFIG_MAP` or `API_AND_CONFIG_MAP`. And a module
whose default silently selects a deprecated authorization mechanism is a trap rather
than a choice.

### `bootstrap_cluster_creator_admin_permissions` defaults to `false`

Not the AWS default. It grants cluster-admin to whichever principal ran the apply, and:

- **It is invisible.** The resulting access is no resource in Terraform, so "who
  administers this cluster?" cannot be answered from the configuration.
- **It depends on who applied.** A pipeline role gets admin when the pipeline creates
  the cluster; a person gets it when they apply from a workstation. Configuration should
  not mean different things depending on who ran it.

`access_entries` makes each grant an explicit, reviewable resource instead.

**Changing this replaces the cluster.** It has to be right the first time.

A `precondition` refuses to build a cluster with no administrator: with the bootstrap
grant off and `authentication_mode = API`, there is no ConfigMap to fall back on, so a
cluster without an admin access entry is unreachable — fixable only by an out-of-band
API call, which is the untracked-change pattern this repository exists to stop. The
check looks for `AmazonEKSClusterAdminPolicy` at cluster scope specifically, because an
entry holding only a namespace-scoped view policy would satisfy "at least one entry"
while still leaving nobody able to administer anything.

### `support_type` defaults to `STANDARD`

Under `EXTENDED`, a cluster that reaches the end of standard support keeps running and
**quietly starts billing at the extended-support rate**. `STANDARD` forces an upgrade
instead, which is the outcome you want to be pushed into rather than the invoice.

## Create-time-only arguments

These cannot be changed later; changing them means a new cluster.

- `service_ipv4_cidr` — the Service CIDR
- `secrets_kms_key_arn` — envelope encryption of Secrets in etcd
- `bootstrap_cluster_creator_admin_permissions`

## Access entries

The replacement for `aws-auth`. Each entry maps an IAM principal into the cluster; each
association grants it a scoped set of Kubernetes permissions. Both are real resources,
so `terraform state list` answers "who can reach this cluster?" — which the ConfigMap
never could.

Associations are keyed by `entry-name/policy-name`, never by index, so adding a policy
to one principal cannot renumber another's.

`policy_arn` must be an **EKS access policy**
(`arn:aws:eks::aws:cluster-access-policy/...`), not an IAM policy. The two look similar
and the API rejects the wrong one with a message that does not say which kind it wanted,
so it is checked at plan time.

## Inputs

Required: `org_prefix`, `environment`, `owner`, `kubernetes_version`, `cluster_role_arn`,
`subnet_ids`.

| Optional | Default | Notes |
|---|---|---|
| `access_entries` | `{}` | But a cluster with no administrator is rejected |
| `bootstrap_cluster_creator_admin_permissions` | `false` | Changing it replaces the cluster |
| `endpoint_public_access` | `true` | Closing it needs VPC endpoints first |
| `endpoint_private_access` | `true` | Keeps node traffic off the NAT gateway |
| `public_access_cidrs` | `["0.0.0.0/0"]` | Same as AWS's default, stated so it shows in a diff |
| `enabled_cluster_log_types` | `["api","audit","authenticator"]` | The useful set, not the cheap one |
| `support_type` | `"STANDARD"` | |
| `service_ipv4_cidr` | `null` | Create-time only |
| `secrets_kms_key_arn` | `null` | Create-time only |
| `deletion_protection` | `false` | |
| `extra_tags` | `{}` | Merged first; mandatory tags win |

## Outputs

`name`, `arn`, `endpoint`, `certificate_authority_data`, `cluster_security_group_id`,
`kubernetes_version`, `platform_version`, `status`, `inventory`.

**`cluster_security_group_id`** is the group EKS creates and manages for
control-plane-to-node traffic. Every managed node group joins it automatically. Add
rules to it rather than building a parallel group, or there are two sources of truth for
what can reach the nodes.

**`inventory.administrators`** lists every cluster-admin in one place, and names the
implicit creator grant explicitly when it is in play. **`inventory.publicly_reachable`**
is true when the endpoint is open to `0.0.0.0/0` — the most consequential setting here,
so it is answerable without reading configuration.

## Tests

```sh
terraform -chdir=modules/eks-cluster test
```

19 tests, `command = plan`, no credentials — verified with every AWS environment
variable unset. Roughly half assert that bad input is rejected, including the two that
matter most: a cluster with no administrator, and an IAM policy ARN where an EKS access
policy belongs.
