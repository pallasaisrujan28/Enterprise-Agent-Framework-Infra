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
`private_route_table_ids`, `availability_zones`, `nat_gateway_ids`, and `inventory`.

Two worth explaining.

**`availability_zones`** is propagated rather than left to be recomputed. AWS
requires that any subnet added to a cluster later be in the same set of AZs as those
given at creation, which makes the chosen set a durable fact about the cluster.

**`private_route_table_ids`** exists for Step 10. Closing the public cluster
endpoint requires VPC interface endpoints — including
`com.amazonaws.<region>.oidc-eks`, without which IRSA token validation fails from
inside the VPC with `NXDOMAIN` — and those attach to route tables.

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
