# `workloads/dev/platform` — L1

The first layer that creates anything. VPC, EKS control plane, core add-ons, one node
pool, and the four IAM roles those need.

```
  network ──────────────────────────────────────┐
                                                │
  eks_cluster_role ─┐                           │
                    ├──▶ eks_cluster ◀──────────┘  private subnets
  access entry ─────┘         │
                              ├──▶ addon vpc-cni            (prefix delegation ON)
                              ├──▶ addon kube-proxy
                              ├──▶ addon eks-pod-identity-agent
                              │         │
                              │         ▼
  eks_node_role ──────────────┴──▶ node_group_default
                                          │
                                          ▼
                              ├──▶ addon coredns
                              └──▶ addon aws-ebs-csi-driver
```

## Apply

There is no local apply. The state lives in the management account's bucket and the
layer is applied by dispatching the workflow:

**Actions → Apply workloads layer** → `target: dev`, `layer: platform`,
`plan_only: ✓`

Review the plan in the run summary, then dispatch again with `plan_only` unchecked. The
apply is gated on the `dev` environment and applies the **saved plan** from the plan
job, so what runs is what was reviewed.

## The backend key is not a free choice

`bootstrap/seed` grants `eaf-baseline-dev-role` read/write on `workloads/dev/*` and
nothing else under `workloads/`. A key outside that prefix fails at `terraform init`
with `AccessDenied`, which reads as a credentials problem rather than a naming one.

The same grant covers locking — `s3:DeleteObject` only on `workloads/dev/*.tflock` — so
`use_lockfile` works at this key and would not one level up.

## Add-on ordering is declared here, not in the modules

Three add-ons must be `ACTIVE` **before** the node group: a node that registers with no
CNI fails with `NodeCreationFailure: NetworkPluginNotReady` and stays `NotReady`. Two
must come **after**: their pods have nowhere to schedule on an empty cluster, so the
add-on sits `DEGRADED` until Terraform times out.

`modules/eks-addon` cannot enforce either direction. Taking a node-group value as an
input would make the whole module wait on the node group, which waits on the cluster — a
cycle. So the `depends_on` lines in `main.tf` are load-bearing, and their comments say
so.

## Decisions made here rather than in a module

**Prefix delegation is on from the first apply.** It changes how the CNI allocates
addresses to an instance *at launch*, so enabling it later requires replacing nodes.
Without it an `m6i.large` stops at 29 pods while barely touching 8 GiB of memory; with
it the ceiling is 110.

**The cluster-admin access entry names `OrganizationAccountAccessRole`, not
`eaf-baseline-dev-role`.** The provider assumes the former, so that is the identity EKS
sees. The latter lives in the management account, and an access-entry principal must be
a role in the cluster's own account. Naming the wrong one yields a cluster the pipeline
cannot administer, discovered at the first `kubectl` call rather than at apply.

**All four roles take a boundary exemption.** `eaf-workload-boundary` denies `ec2:*` and
`eks:*` — exactly what a cluster and node role exist to do. These roles are assumed only
by AWS service principals and carry only AWS-managed policies, so the cap is the trust
policy, not a boundary.

**`AmazonEKS_CNI_Policy` is not on the node role.** It permits attaching network
interfaces and assigning IPs; on the node role every pod inherits it via instance
metadata. It sits on the `vpc-cni` add-on's own Pod Identity role.

**No taints, and one pool.** The design's earlier `langfuse` pool and its taint are
gone: with one pool tainted, untainted capacity was a single `t3.medium` at 17 pod slots,
which caused the starvation the taint was meant to prevent.

## Add-on versions are pinned

All five verified as the AWS default for Kubernetes 1.36 in `eu-west-2` on 2026-08-31.
Pinned rather than omitted, because omitting a version installs whatever is default *at
apply time* — so two applies from identical configuration would install different
software, and the difference would read as drift.

```sh
aws eks describe-addon-versions --kubernetes-version 1.36 --addon-name vpc-cni \
  --query 'addons[0].addonVersions[?compatibilities[0].defaultVersion==`true`].addonVersion'
```

## Cluster access

`authentication_mode` is `API`, so the access entries in this layer are the **only** way
to reach the Kubernetes API. There is no `aws-auth` ConfigMap to fall back on, and the
symptom of getting it wrong is an authorization error from `kubectl` that points at
nothing.

Three sources, all visible in the `cluster_admins` output:

| Source | What |
|---|---|
| `deployer` | `OrganizationAccountAccessRole`, which the provider assumes. Without it this layer cannot manage the cluster |
| `sso_admin_permission_sets` | Humans, via IAM Identity Center. **Discovered, not hardcoded** |
| `additional_cluster_admin_role_arns` | Anything named explicitly |

### Why the SSO roles are discovered

Identity Center appends a random suffix to the role it creates for a permission set —
`AWSReservedSSO_AWSAdministratorAccess_a8fd6486dea1ff46`. **That suffix changes if the
permission set is reprovisioned**, and AWS is explicit that an access entry stops working
when its principal is recreated *even at the same ARN*, because the entry is keyed to the
role's id. Hardcoding it works until it silently doesn't.

So `data.aws_iam_roles` looks them up by permission set name, anchored on both sides.
The anchoring matters: this account has both `AdministratorAccess` **and**
`AWSAdministratorAccess`, and a loose pattern would grant cluster-admin to a permission
set nobody asked for.

Map keys are the *permission set* name, not the role name, so reprovisioning does not
move the resource address and recreate the entry for no reason.

A `check` block reports any permission set that resolved to something other than exactly
one role. It is a check rather than a precondition on purpose: missing human access is a
degradation, not a breakage — the deployer still has admin, so the layer should still
apply.

**A path in the principal ARN is fine.** AWS documents that an access entry's ARN may
include a path; it is the deprecated `aws-auth` ConfigMap that could not. The two rules
are easy to conflate and an earlier version of this file assumed the stricter one.

### Getting a kubeconfig

```sh
terraform output -raw kubeconfig_command   # or just:
aws eks update-kubeconfig --name eaf-dev --region eu-west-2
```

Then confirm prefix delegation actually took effect — this is the number it changes:

```sh
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.pods}'
```

Expect **110** per node. `29` means prefix delegation is not active, and it cannot be
fixed on running nodes — they have to be replaced.

## Tearing it down

```
Actions → Destroy workloads → target: dev, layer: platform, plan_only: ✓
```

Same shape as the apply: dry run by default, then dispatch again with `plan_only`
unchecked and `destroy` typed in the confirm field.

**Destroy in reverse dependency order.** This layer holds the cluster, so destroying it
while `cluster-addons` or `apps` still have state leaves those layers pointing at a
cluster that no longer exists — and their own destroy then cannot run, because the
Kubernetes provider cannot reach an endpoint that is gone.

## Outputs

`platform_inventory` is one structured record of the whole layer, intended to make a
review possible without reading the plan. `iam_roles` feeds `make iam-inventory`.

The rest exist because L2 and L3 read them through `terraform_remote_state`:
`cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data`,
`cluster_security_group_id`, `private_subnet_ids`, `private_subnet_ids_by_az`,
`private_route_table_ids`, `node_group_labels`, `node_group_tolerations`,
`availability_zones`, `nat_public_ips`, `vpc_id`.

`node_group_tolerations` is empty while the pool is untainted, and present anyway so a
workload can consume it unconditionally and keep working if a taint is added later.
