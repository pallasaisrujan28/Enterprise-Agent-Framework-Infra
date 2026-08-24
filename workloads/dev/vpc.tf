# VPC for EAF-DEV workloads.
#
# The default VPC that CT creates is all-public and unsuitable for EKS.
# This VPC has proper public/private subnet separation:
#   public subnets  — NAT gateway, load balancers
#   private subnets — EKS worker nodes, Aurora
#
# Dev uses a single NAT gateway (not HA) to keep costs down.
# Prod uses one NAT gateway per AZ.

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
}

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "${var.cluster_name}-vpc"
    Environment = "dev"
    ManagedBy   = "terraform"

    # EKS requires these tags to discover subnets automatically.
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ── Internet gateway ───────────────────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name      = "${var.cluster_name}-igw"
    ManagedBy = "terraform"
  }
}

# ── Public subnets ─────────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.cluster_name}-public-${local.azs[count.index]}"
    ManagedBy                = "terraform"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name      = "${var.cluster_name}-public-rt"
    ManagedBy = "terraform"
  }
}

resource "aws_route_table_association" "public" {
  count = length(local.azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── NAT gateway (single for dev — not HA, lower cost) ─────────────────────────

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name      = "${var.cluster_name}-nat-eip"
    ManagedBy = "terraform"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name      = "${var.cluster_name}-nat"
    ManagedBy = "terraform"
  }

  depends_on = [aws_internet_gateway.this]
}

# ── Private subnets ────────────────────────────────────────────────────────────

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "${var.cluster_name}-private-${local.azs[count.index]}"
    ManagedBy                         = "terraform"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name      = "${var.cluster_name}-private-rt"
    ManagedBy = "terraform"
  }
}

resource "aws_route_table_association" "private" {
  count = length(local.azs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
