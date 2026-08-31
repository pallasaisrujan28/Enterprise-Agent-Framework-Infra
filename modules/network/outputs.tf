output "vpc_id" {
  description = "VPC id. Pass as an attribute reference, never a reconstructed string."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block. Useful for security group rules that permit intra-VPC traffic."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet ids, ordered by availability zone. Internet-facing load balancers and NAT gateways."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet ids, ordered by availability zone. The cluster and every node group go here."
  value       = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  description = "Private route table ids, one per AZ. Needed to attach VPC endpoints — which Step 10 requires when the cluster endpoint goes private."
  value       = aws_route_table.private[*].id
}

output "availability_zones" {
  description = <<-EOT
    The availability zones used, in the order subnets were created.

    Worth propagating rather than recomputing: AWS requires that any subnet added to
    a cluster later be in the same set of AZs as those given at creation, so the
    chosen set is a durable fact about the cluster, not an incidental one.
  EOT
  value       = local.azs
}

output "nat_gateway_ids" {
  description = "NAT gateway ids. One element when single_nat_gateway is true, otherwise one per AZ."
  value       = aws_nat_gateway.this[*].id
}

output "inventory" {
  description = "Structured record of this network, for cross-layer inventory and review."
  value = {
    vpc_id             = aws_vpc.this.id
    vpc_cidr           = aws_vpc.this.cidr_block
    availability_zones = local.azs
    az_count           = var.az_count

    public_subnets  = [for s in aws_subnet.public : { id = s.id, cidr = s.cidr_block, az = s.availability_zone }]
    private_subnets = [for s in aws_subnet.private : { id = s.id, cidr = s.cidr_block, az = s.availability_zone }]

    # Usable addresses per subnet, after the 5 AWS reserves. Surfaced because it is
    # the real pod-IP budget once prefix delegation is on, and it is the number that
    # silently constrains node density.
    usable_ips_per_subnet = pow(2, 32 - tonumber(split("/", local.private_cidrs[0])[1])) - 5

    nat_gateway_count  = local.nat_count
    single_nat_gateway = var.single_nat_gateway
  }
}
