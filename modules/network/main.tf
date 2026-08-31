# VPC, subnets, and egress for an EKS cluster.
#
# Deliberately knows nothing about EKS beyond the two things EKS actually needs
# from a network: subnets in at least two availability zones, and the load-balancer
# discovery tags. It takes no cluster_name, so one network can outlive or precede
# any particular cluster.

locals {
  name = "${var.org_prefix}-${var.environment}"

  mandatory_tags = {
    ManagedBy       = "terraform"
    ManagedByModule = "modules/network"
    OrgPrefix       = var.org_prefix
    Environment     = var.environment
    Owner           = var.owner
  }

  tags = merge(var.extra_tags, local.mandatory_tags)

  # sort() is not cosmetic. Which CIDR a zone gets is decided by its POSITION in
  # this list, so as long as the order comes from the API, a reordering silently
  # renumbers every subnet and forces replacement. AWS documents no ordering
  # guarantee for this data source. Sorting makes the address plan a pure function of
  # the SET of zone names, so the same inputs always carve the same map.
  available_azs = sort(data.aws_availability_zones.available.names)

  # min() rather than slicing straight to var.az_count. A bare slice past the end of
  # the list raises "end index must not be greater than the length of the list",
  # which names a function argument instead of telling the caller that the region
  # does not have that many zones. Clamping here keeps the expression valid so the
  # precondition on aws_vpc can report the real problem.
  azs = slice(local.available_azs, 0, min(var.az_count, length(local.available_azs)))

  # Subnets are keyed BY AVAILABILITY ZONE NAME, not by list index.
  #
  # This is the "for_each over a map, never count over a list" convention, and here
  # it is load-bearing rather than stylistic. local.azs comes from a data source. If
  # AWS ever returns those names in a different order, count-based addressing moves
  # aws_subnet.public[0] from eu-west-2a to eu-west-2b — and Terraform destroys and
  # recreates subnets in different availability zones, taking the cluster's network
  # interfaces and everything in them.
  #
  # AWS makes AZ identity load-bearing too: any subnet added to a cluster later must
  # be in the same set of zones given at creation. Keying by zone name means the
  # resource address IS the zone, so a reordering is a no-op and removing a zone
  # removes only that zone's subnets.
  #
  # Public takes the first az_count blocks, private the next az_count. Computed
  # rather than listed, so changing az_count or subnet_newbits needs no hand-edited
  # CIDRs — which is how the previous configuration ended up with six hardcoded /24s.
  public_cidr_by_az  = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, var.subnet_newbits, i) }
  private_cidr_by_az = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, var.subnet_newbits, i + var.az_count) }

  # One NAT, or one per AZ. With a single NAT it lives in the first zone
  # alphabetically — deterministic, so the choice does not drift between plans.
  nat_azs = var.single_nat_gateway ? slice(local.azs, 0, 1) : local.azs

  # Which NAT each private subnet routes through. With one NAT every zone shares it;
  # with one per zone each routes to its own, so traffic never crosses an
  # availability boundary.
  nat_az_for = { for az in local.azs : az => var.single_nat_gateway ? local.azs[0] : az }
}

data "aws_availability_zones" "available" {
  state = "available"

  # Exclude Local Zones and Wavelength Zones. They appear in this list, they are
  # not valid for EKS subnets, and the failure arrives at cluster creation rather
  # than here.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are required by EKS. AWS is explicit: without DNS hostname and DNS
  # resolution support, nodes cannot register with the cluster. This is not a
  # nice-to-have and the failure is opaque, so it is not configurable here.
  enable_dns_support   = true
  enable_dns_hostnames = true

  # NOT set: kubernetes.io/cluster/<name> = "shared".
  #
  # The previous configuration tagged the VPC with it and commented "EKS requires
  # these tags to discover subnets automatically." That is not correct. AWS applied
  # that tag to clusters on Kubernetes 1.14 and earlier, states it was only used by
  # Amazon EKS, and says it can be removed without impacting services and is not
  # used from 1.15 onwards. Subnet discovery uses the kubernetes.io/role/* tags
  # below, which live on the SUBNETS, not on the VPC.

  tags = merge(local.tags, { Name = "${local.name}-vpc" })

  # Subnet-SIZING checks are not here — they live on var.subnet_newbits, because
  # locals call cidrsubnet() and Terraform evaluates locals before resource
  # preconditions, so a precondition would be unreachable for exactly the inputs it
  # was meant to catch.
  #
  # This one has to be here rather than on the variable: it depends on a data
  # source, so the answer is not knowable from the inputs alone.
  lifecycle {
    precondition {
      condition = length(local.azs) == var.az_count
      error_message = format(
        "az_count is %d but this region has only %d usable availability zones (%s). Local Zones and Wavelength Zones are excluded because EKS cannot use them.",
        var.az_count,
        length(local.available_azs),
        join(", ", local.available_azs),
      )
    }
  }
}

# ── Public subnets: internet-facing load balancers, and the NAT gateways ──────

resource "aws_subnet" "public" {
  for_each = local.public_cidr_by_az

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key

  # Required for managed node groups deployed to a public subnet. No nodes are
  # placed here — they go in private subnets — but load balancers and anything
  # else public needs it, and AWS requires it for managed node groups in public
  # subnets on or after 22 April 2020.
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${local.name}-public-${each.key}"

    # Marks this subnet as a candidate for INTERNET-FACING load balancers.
    # Without it the AWS Load Balancer Controller cannot discover the subnet and a
    # Service of type LoadBalancer fails to provision — with an error about subnets
    # rather than about tags.
    "kubernetes.io/role/elb" = "1"

    Tier = "public"
  })
}

# ── Private subnets: every node, and internal load balancers ─────────────────

resource "aws_subnet" "private" {
  for_each = local.private_cidr_by_az

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = merge(local.tags, {
    Name = "${local.name}-private-${each.key}"

    # Marks this subnet as a candidate for INTERNAL load balancers.
    "kubernetes.io/role/internal-elb" = "1"

    Tier = "private"
  })
}

# ── Internet gateway and public routing ──────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ── NAT and private routing ──────────────────────────────────────────────────
#
# Nodes sit in private subnets and pull outbound: images from ECR, the EKS API
# endpoint, Bedrock. Nothing reaches in. A NAT gateway provides that one-way path.
#
# Step 10 of the design closes the public cluster endpoint, at which point node to
# control-plane traffic stays inside the VPC and the NAT carries only genuine
# internet egress.

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  # Named for the zone, not an index. An elastic IP is a billable, allocatable
  # object and its address is quoted in firewall allowlists downstream, so a stable
  # identity that survives a change to az_count matters more here than most places.
  tags = merge(local.tags, { Name = "${local.name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(local.tags, { Name = "${local.name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

# One route table per private subnet even when sharing a single NAT. It costs
# nothing, and it means switching single_nat_gateway to false later changes routes
# rather than restructuring route tables.
resource "aws_route_table" "private" {
  for_each = toset(local.azs)

  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-private-${each.key}" })
}

resource "aws_route" "private_nat" {
  # Keyed by the private subnet's zone; the value is the zone whose NAT it uses.
  # With one NAT every zone maps to the same one, with one per zone each maps to
  # itself, so this single expression covers both without a conditional.
  for_each = local.nat_az_for

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.value].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}
