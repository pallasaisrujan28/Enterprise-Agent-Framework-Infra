output "vpc_id" {
  description = "VPC id. Pass as an attribute reference, never a reconstructed string."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block. Useful for security group rules that permit intra-VPC traffic."
  value       = aws_vpc.this.cidr_block
}


# The subnet resources are keyed by availability zone, so these iterate local.azs
# rather than using a splat. That keeps the documented ordering an explicit promise
# instead of a side effect of how Terraform happens to order map keys.

output "public_subnet_ids" {
  description = "Public subnet ids, ordered by availability zone. Internet-facing load balancers and NAT gateways."
  value       = [for az in local.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet ids, ordered by availability zone. The cluster and every node group go here."
  value       = [for az in local.azs : aws_subnet.private[az].id]
}

output "public_subnet_ids_by_az" {
  description = "Public subnet ids keyed by availability zone, for callers that must place a resource in a specific zone."
  value       = { for az in local.azs : az => aws_subnet.public[az].id }
}

output "private_subnet_ids_by_az" {
  description = <<-EOT
    Private subnet ids keyed by availability zone.

    Useful for anything zone-pinned: an EBS volume only attaches to a node in the
    same zone, so a stateful workload's node group and its storage have to agree on
    one, and a list index is a poor way to express that agreement.
  EOT
  value       = { for az in local.azs : az => aws_subnet.private[az].id }
}

output "private_route_table_ids" {
  description = "Private route table ids, one per AZ. Needed to attach VPC endpoints — which Step 10 requires when the cluster endpoint goes private."
  value       = [for az in local.azs : aws_route_table.private[az].id]
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
  value       = [for az in local.nat_azs : aws_nat_gateway.this[az].id]
}

output "nat_public_ips" {
  description = <<-EOT
    The NAT gateways' public IP addresses, ordered by availability zone.

    This is the source address every outbound connection from a node appears to come
    from, so it is what a third party puts in an allowlist. Surfaced as an output so
    that fact is discoverable without reading the console.
  EOT
  value       = [for az in local.nat_azs : aws_eip.nat[az].public_ip]
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
    usable_ips_per_subnet = pow(2, 32 - tonumber(split("/", local.private_cidr_by_az[local.azs[0]])[1])) - 5

    nat_gateway_count  = length(local.nat_azs)
    single_nat_gateway = var.single_nat_gateway
  }
}
