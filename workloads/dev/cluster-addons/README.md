# `workloads/dev/cluster-addons` — L2

Namespaces, their baseline, and the StorageClass workloads use. **Kubernetes objects
only** — this layer creates no AWS resources.

```
Actions → Apply workloads layer → target: dev, layer: cluster-addons, plan_only: ✓
```

## What it creates

| | |
|---|---|
| `gp3` StorageClass | CSI provisioner, encrypted, expandable, `WaitForFirstConsumer`, **cluster default** |
| Namespaces | `eaf`, `monitoring`, `memory`, `tools` |
| Per namespace | default-deny ingress NetworkPolicy, plus quotas and default container limits |

## Reading the cluster from the platform layer

The `kubernetes` provider is configured from `workloads/dev/platform`'s outputs via
`terraform_remote_state` — never by looking the cluster up by name.

A data source would also work, and would also let this layer apply against a cluster the
platform layer does not manage. Reading the state makes the dependency explicit and turns
a missing platform layer into an obvious error rather than an empty result.

It also avoids RC2's shape: the provider is configured from values that **already exist**
in another layer's state, not from anything this layer creates. A provider cannot depend on
its own output.

### The `--role-arn` is load-bearing

```hcl
args = ["eks", "get-token", "--cluster-name", ..., "--role-arn", "...OrganizationAccountAccessRole"]
```

The pipeline authenticates as a role in the **management** account. The cluster's access
entry is for `OrganizationAccountAccessRole` in **EAF-DEV**. Omit `--role-arn` and the
token is a perfectly valid AWS identity the cluster has never heard of — you get a 401 from
the Kubernetes API, which reads as a missing access entry rather than the wrong identity.

It mirrors the `assume_role` in the `aws` provider, and the two must agree.

## The NetworkPolicy trap

**A NetworkPolicy is an object the API server stores whether or not anything enforces it.**
With no enforcer, `kubectl get networkpolicy` lists your default-deny rule, `describe`
shows it selecting every pod, and traffic flows exactly as before. It looks configured.

On EKS the enforcer is the VPC CNI's node agent, and it is **off by default**. Verified on
this cluster before it was enabled:

```
aws-eks-nodeagent args: [... "--enable-network-policy=false" ...]
```

The `aws-eks-nodeagent` **container was already running**. Its presence proves nothing —
only the flag does.

Enforcement is switched on in **L1**, in the `vpc-cni` add-on's configuration
(`enableNetworkPolicy = "true"`), because it is a property of the CNI. This layer takes
`network_policy_enforced` as an **assertion**: when false, `modules/k8s-namespace` creates
**no policy** and labels the namespace
`eaf.io/network-policy=NOT-ENFORCED-no-enforcer-in-cluster`, rather than leaving something
that reads as protection.

Check it after any CNI change:

```sh
terraform output network_policy_state
kubectl get ns --show-labels | grep network-policy
```

### Only ingress is denied

Denying egress as well would stop pods reaching cluster DNS, and the symptom is every
hostname failing to resolve — which reads as a broken CoreDNS rather than a NetworkPolicy.
Egress restriction belongs with a policy that also permits port 53 to `kube-system`.

## Storage

`gp3`, and it is now the cluster default. Before this layer, **the cluster had no default
at all** — AWS stopped annotating its `gp2` class as default at EKS 1.30 — so a chart
omitting `storageClassName` produced a PVC that waited forever with nothing in its events
explaining why.

`WaitForFirstConsumer` matters more than it looks: an EBS volume lives in **one**
availability zone. Creating it before the pod is scheduled pins the scheduler to that
zone, and a pod it cannot place there stays `Pending` with an error about node affinity
rather than storage.

### `gp2` is left alone, deliberately

EKS creates a `gp2` StorageClass on every new cluster. This layer does **not** manage it:

- no PVC references it, so it has provisioned nothing and **costs nothing** — it is an
  unused recipe
- deleting it invites EKS to recreate it
- adopting it would mean owning a resource we do not want

It is recorded in `cluster_addons_inventory.storage.unmanaged_note` so it appears in review
rather than only in the cluster. Property 7 asks that unmanaged objects be *accounted for*,
not that they cannot exist. Full reasoning in `learnings/006`.

## Quotas

Set where overuse produces a **bill** rather than a `Pending` pod — `persistentvolumeclaims`
in particular, since each one becomes an EBS volume.

Default container requests and limits are paired with each quota on purpose: a container
declaring no request counts as **zero** against a quota while still occupying real node
capacity, which makes the quota a poor description of what is running.

## Destroying

```
Actions → Destroy workloads → target: dev, layer: cluster-addons
```

**Destroy this before `platform`.** This layer's provider needs a reachable Kubernetes
endpoint; if the cluster is gone, its own destroy cannot run and the state has to be
cleaned by hand.

## Outputs

`namespace_names`, `storage_class_name`, `network_policy_state`, and
`cluster_addons_inventory`.

`cluster_addons_inventory.ingress_default_deny_effective` is a single boolean answering
"is ingress actually restricted?" — true only when a policy exists **and** something
enforces it, so it cannot read as protected when it is not.
