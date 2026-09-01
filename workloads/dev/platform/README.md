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

## After the first apply

Two things this layer cannot verify for itself:

- **`kubectl` access for a human.** `additional_cluster_admin_role_arns` is empty. Add
  your SSO role once the cluster exists — AWS documents removing the *path* from a role
  ARN for cluster access, and an SSO ARN contains
  `/aws-reserved/sso.amazonaws.com/<region>/`, so this is worth verifying against the
  live cluster rather than guessing. A wrong ARN produces an entry that silently never
  matches.
- **That prefix delegation took effect.** `kubectl get node -o jsonpath='{..allocatable.pods}'`
  should report 110, not 29.

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
