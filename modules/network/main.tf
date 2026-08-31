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

  available_azs = data.aws_availability_zones.available.names

  # min() rather than slicing straight to var.az_count. A bare slice past the end of
  # the list raises "end index must not be greater than the length of the list",
  # which names a function argument instead of telling the caller that the region
  # does not have that many zones. Clamping here keeps the expression valid so the
  # precondition on aws_vpc can report the real problem.
  azs = slice(local.available_azs, 0, min(var.az_count, length(local.available_azs)))

  # Public subnets take the first az_count blocks, private the next az_count. Both
  # are computed rather than listed, so changing az_count or subnet_newbits does not
  # require hand-editing CIDRs — which is how the previous configuration ended up
  # with three hardcoded /24s.
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, var.subnet_newbits, i)]
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, var.subnet_newbits, i + var.az_count)]

  # One NAT, or one per AZ. Private subnets route to the NAT in their own AZ when
  # there is one, otherwise to the single shared NAT.
  nat_count = var.single_nat_gateway ? 1 : var.az_count
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
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Required for managed node groups deployed to a public subnet. No nodes are
  # placed here — they go in private subnets — but load balancers and anything
  # else public needs it, and AWS requires it for managed node groups in public
  # subnets on or after 22 April 2020.
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${local.name}-public-${local.azs[count.index]}"

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
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name = "${local.name}-private-${local.azs[count.index]}"

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
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
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
  count = local.nat_count

  domain = "vpc"
  tags   = merge(local.tags, { Name = "${local.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, { Name = "${local.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

# One route table per private subnet even when sharing a single NAT. It costs
# nothing, and it means switching single_nat_gateway to false later changes routes
# rather than restructuring route tables.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-private-${local.azs[count.index]}" })
}

resource "aws_route" "private_nat" {
  count = var.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"

  # With one NAT, every private subnet routes to it. With one per AZ, each routes
  # to the NAT in its own zone so traffic never crosses an availability boundary.
  nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
