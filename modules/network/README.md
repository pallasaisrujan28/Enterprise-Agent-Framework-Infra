# `modules/network`

VPC, subnets and egress for an EKS cluster.

Takes **no `cluster_name`**. It knows only the two things EKS actually needs from a
network — subnets in at least two availability zones, and the load-balancer
discovery tags — so one network can precede or outlive any particular cluster.

## Usage

```hcl
module "network" {
  source = "../../../../modules/network"

  org_prefix  = var.org_prefix
  environment = "dev"
  owner       = "platform-team"

  vpc_cidr           = "10.0.0.0/16"
  az_count           = 2
  single_nat_gateway = true    # dev. prod passes false
}
```

## What the previous configuration got right

Worth stating, because most of this module is a faithful reproduction rather than a
correction. The retired `vpc.tf` already had:

- `enable_dns_support` and `enable_dns_hostnames` both true
- `kubernetes.io/role/elb = 1` on public subnets
- `kubernetes.io/role/internal-elb = 1` on private subnets
- `map_public_ip_on_launch` on public subnets only
- Nodes in private subnets behind a NAT gateway

That is the correct shape, and getting those tags right is not obvious. The changes
below are a removal, a generalisation and a sizing decision — not a rescue.

## Three changes from the retired configuration

### 1. The VPC-level cluster tag is gone

The old configuration tagged the **VPC** with
`kubernetes.io/cluster/<name> = "shared"` and commented *"EKS requires these tags to
discover subnets automatically."*

That is not correct. AWS applied that tag to clusters on Kubernetes 1.14 and
earlier, states it was only used by Amazon EKS, and says it can be removed without
impacting services and is unused from 1.15 onwards. Subnet discovery uses the
`kubernetes.io/role/*` tags, which live on the **subnets**.

A test asserts the VPC carries no `kubernetes.io/cluster/*` tag, so it cannot come
back by copy-paste.

### 2. Subnet CIDRs are computed, not listed

The old configuration hardcoded six blocks:

```hcl
public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnets = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
```

Changing the AZ count or the VPC CIDR meant hand-editing addresses. Here they come
from `cidrsubnet()`, driven by `az_count` and `subnet_newbits`, with public taking
the first `az_count` blocks and private the next.

### Subnets are keyed by availability zone

Every per-zone resource uses `for_each` over a map keyed by AZ name — never `count`
over a list. This one is load-bearing rather than stylistic.

The zone list comes from `data.aws_availability_zones`, and AWS documents no ordering
guarantee for it. Under index-based addressing, a reordering moves
`aws_subnet.public[0]` from `eu-west-2a` to `eu-west-2b`; Terraform's answer to a
changed `availability_zone` is destroy and create, so the cluster's network interfaces
and every pod IP go with it. Keying by zone name makes the resource address *be* the
zone.

`local.available_azs` is also `sort()`ed, which closes the other half of the problem:
which CIDR a zone receives depends on its position in the list, so without sorting a
reordering renumbers subnets and forces replacement even when each one stays in its
own zone. Sorting makes the address plan a pure function of the *set* of zone names.

Two tests cover this — `zone_ordering_from_the_api_does_not_move_subnets` plans against
a deliberately shuffled zone list, and
`dropping_an_az_leaves_the_remaining_subnets_untouched` checks that lowering
`az_count` renumbers nothing that survives.

`count` is still the right tool for conditional *creation* (`? 1 : 0`), where nothing
can shift. The rule is about list indices.

### 3. Subnets default to `/20`, not `/24`

This one interacts with a decision made elsewhere, and it is the reason the default
is generous.

Pod IP addresses come from these subnets. With **prefix delegation** enabled on the
VPC CNI, the CNI reserves `/28` blocks per node rather than single addresses. A node
at the full 110-pod cap can hold roughly 112 addresses:

| subnet | usable addresses | nodes at full pod density |
|---|---|---|
| `/24` | 251 | ~2 |
| `/20` | 4,091 | ~36 |

The planned workload is around 27 pods in total, far below that density, so a `/24`
would work today. But a `/20` removes the interaction entirely and costs nothing: a
`/16` yields sixteen `/20`s and only four are used at `az_count = 2`.

Pass `subnet_newbits = 8` for `/24`s if a smaller VPC ever makes that necessary.

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `org_prefix` | string | — | Required. Validated `^[a-z][a-z0-9]{1,11}$` |
| `environment` | string | — | Required. `dev` / `test` / `staging` / `prod` |
| `owner` | string | — | Required. Surfaced as a tag |
| `vpc_cidr` | string | `10.0.0.0/16` | Must be `/20` or larger |
| `az_count` | number | `2` | Minimum 2 — EKS requires two AZs |
| `subnet_newbits` | number | `4` | `4` → `/20`, `8` → `/24` |
| `single_nat_gateway` | bool | `true` | `false` gives one NAT per AZ |
| `extra_tags` | map | `{}` | Merged first; mandatory tags win |

## Outputs

`vpc_id`, `vpc_cidr`, `public_subnet_ids`, `private_subnet_ids`,
`public_subnet_ids_by_az`, `private_subnet_ids_by_az`, `private_route_table_ids`,
`availability_zones`, `nat_gateway_ids`, `nat_public_ips`, and `inventory`.

The list forms are ordered by availability zone, not by the order the AWS API
happened to reply in. A few worth explaining.

**`availability_zones`** is propagated rather than left to be recomputed. AWS
requires that any subnet added to a cluster later be in the same set of AZs as those
given at creation, which makes the chosen set a durable fact about the cluster.

**`private_subnet_ids_by_az`** exists for anything zone-pinned. An EBS volume only
attaches to a node in its own zone, so a stateful workload's node group and its
storage have to agree on one — and a list index is a poor way to express that.

**`nat_public_ips`** is the source address every outbound connection from a node
appears to come from, which is what a third party puts in an allowlist.

**`private_route_table_ids`** exists for Step 10. Closing the public cluster endpoint
requires VPC interface endpoints — `ec2`, `ecr.api`, `ecr.dkr`, `sts`, `logs` and an S3
gateway endpoint among them — and those attach to route tables.

Note the platform uses **Pod Identity**, not IRSA, so
`com.amazonaws.<region>.oidc-eks` is *not* among them. Under IRSA it would be
mandatory: without it, resolving the cluster's OIDC issuer from inside a VPC that has no
outbound internet fails with `NXDOMAIN`. Pod Identity has no OIDC issuer to resolve.

## NAT topology

`single_nat_gateway = true` (default) puts one NAT in the first public subnet and
routes every private subnet to it. Cheaper, and one AZ failure removes outbound
internet for all nodes. Acceptable for a disposable dev environment.

`false` puts one NAT per AZ, and each private subnet routes to the NAT in its own
zone so traffic never crosses an availability boundary. Multiplies the hourly cost
by `az_count`.

Either way there is **one route table per private subnet**. It costs nothing, and it
means flipping the flag later changes routes rather than restructuring route tables.

## Validation, and where each check lives

Three checks, in three different places, for reasons worth recording.

**On `var.vpc_cidr`** — valid CIDR, and `/20` or larger.

**On `var.subnet_newbits`** — enough blocks for `az_count × 2` subnets, and subnets
no smaller than `/27`. These reference other variables, so they need Terraform
`>= 1.9`.

They are *not* resource preconditions, and that is deliberate: `locals` call
`cidrsubnet()`, and Terraform evaluates locals **before** resource preconditions. A
precondition would be unreachable for exactly the inputs it was meant to catch —
the caller would instead see `prefix extension of 2 does not accommodate a subnet
numbered 10`, which is accurate but points at a local expression rather than at the
input that was wrong.

**On `aws_vpc.this`, as a precondition** — `az_count` does not exceed the zones the
region actually has. This one *cannot* be a variable validation, because it depends
on a data source. The answer is not knowable from the inputs alone.

One more subtlety, learned by getting it wrong. The `/20`-or-larger check is guarded
with `can(cidrnetmask(...))` and falls through to `true` when the CIDR is malformed:

```hcl
condition = can(cidrnetmask(var.vpc_cidr)) ? tonumber(split("/", var.vpc_cidr)[1]) <= 20 : true
```

Terraform evaluates every validation block. Unguarded, a value like `"not-a-cidr"`
makes `split("/", ...)[1]` raise `Invalid index`, so the caller gets an error about
collection indexing instead of the message telling them it is not a CIDR. **A
validation that crashes is worse than no validation**, because it masks the one that
would have been useful. Each block checks one thing and defers to whichever block
owns the failure.

## Tests

```sh
terraform -chdir=modules/network test
```

20 tests, `command = plan` throughout, a few seconds. Verified to pass with
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_PROFILE`
and `AWS_DEFAULT_REGION` all unset.

`data.aws_availability_zones` is mocked, so the tests do not depend on which zones a
region happens to expose today. Two subnet ids are overridden with
`override_during = plan`, which is what makes the "NAT gateway is in a public
subnet" assertion evaluable — comparing two apply-time-unknown ids cannot work
during a plan.

Eight of the twenty assert that bad input is **rejected**: a single AZ, a `/24` VPC,
a malformed CIDR, a subnet plan that cannot fit, subnets below `/27`, more AZs than
the region has, a bad `org_prefix`, an unknown `environment`.

## Design references

- Right-Sizing Analysis — the pod-density arithmetic behind the `/20` default
- Step 10 — why `private_route_table_ids` is an output
- `learnings/001-eks-ecosystem.md` — where subnets, ENIs and pod IPs fit together
- `learnings/004-prefix-delegation.md` — why subnet size and pod density interact

## Sources

- [Amazon EKS networking requirements for VPC and subnets](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html)
- [Assign more IP addresses to Amazon EKS nodes with prefixes](https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html)
