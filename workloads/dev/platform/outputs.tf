# Outputs are the ONLY way a later layer reads anything from here.
#
# L2 (cluster-addons) and L3 (apps) read these through terraform_remote_state. Nothing
# downstream reconstructs a name or an ARN from a string — a reconstructed value
# creates no dependency edge, so a rename breaks it silently at apply.

output "vpc_id" {
  description = "VPC id."
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet ids, ordered by availability zone."
  value       = module.network.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet ids, ordered by availability zone."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids_by_az" {
  description = "Private subnet ids keyed by AZ. For anything zone-pinned — an EBS volume only attaches to a node in its own zone."
  value       = module.network.private_subnet_ids_by_az
}

output "private_route_table_ids" {
  description = "Private route table ids. Needed to attach the VPC interface endpoints that closing the public cluster endpoint requires."
  value       = module.network.private_route_table_ids
}

output "nat_public_ips" {
  description = "Source addresses every outbound connection from a node appears to come from. What a third party puts in an allowlist."
  value       = module.network.nat_public_ips
}

# ── Cluster ───────────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks_cluster.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint. With certificate_authority_data, configures the kubernetes and helm providers in L2."
  value       = module.eks_cluster.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA certificate for the API server."
  value       = module.eks_cluster.certificate_authority_data
}

output "cluster_security_group_id" {
  description = "The security group EKS manages for control-plane-to-node traffic. Add rules to it rather than building a parallel group."
  value       = module.eks_cluster.cluster_security_group_id
}

output "kubernetes_version" {
  description = "Cluster Kubernetes version."
  value       = module.eks_cluster.kubernetes_version
}

output "availability_zones" {
  description = "AZs in use. Durable: AWS requires any subnet added to the cluster later to be in this same set."
  value       = module.network.availability_zones
}

# ── Node pool ─────────────────────────────────────────────────────────────────

output "node_group_labels" {
  description = "Labels on the default pool. A workload derives its nodeSelector from this rather than restating it."
  value       = module.node_group_default.labels
}

output "node_group_tolerations" {
  description = <<-EOT
    Tolerations for the default pool, already in Kubernetes manifest form.

    Empty while the pool is untainted. Present as an output regardless, so a workload
    in L3 can consume it unconditionally and keeps working if a taint is added later.
  EOT
  value       = module.node_group_default.tolerations
}

# ── IAM ───────────────────────────────────────────────────────────────────────

output "iam_roles" {
  description = <<-EOT
    Every role this layer owns, as an inventory record.

    `make iam-inventory` aggregates this across layers; `make iam-orphans` finds roles
    in the account that appear in no layer's record. Together they are the answer to
    "we lost track of the roles" — this half proves what is owned, the other half
    finds what is not.
  EOT
  value = {
    eks_cluster = module.eks_cluster_role.inventory
    eks_node    = module.eks_node_role.inventory
    vpc_cni     = module.vpc_cni_role.inventory
    ebs_csi     = module.ebs_csi_role.inventory
  }
}

# ── Review surface ────────────────────────────────────────────────────────────

output "platform_inventory" {
  description = "One structured record of this layer, for review without reading the plan."
  value = {
    account_id  = data.aws_caller_identity.current.account_id
    region      = var.region
    environment = var.environment

    network = module.network.inventory
    cluster = module.eks_cluster.inventory
    nodes   = module.node_group_default.inventory

    addons = {
      vpc_cni            = module.addon_vpc_cni.inventory
      kube_proxy         = module.addon_kube_proxy.inventory
      coredns            = module.addon_coredns.inventory
      ebs_csi_driver     = module.addon_ebs_csi.inventory
      pod_identity_agent = module.addon_pod_identity_agent.inventory
    }

    # The two facts most worth checking after an apply, surfaced so neither needs a
    # kubectl session to answer.
    #
    # Pod density: without prefix delegation an m6i.large stops at 29 pods regardless
    # of free memory, and it cannot be enabled later without replacing nodes.
    prefix_delegation_enabled = module.addon_vpc_cni.inventory.prefix_delegation_on

    # Whether the pod-IP budget is actually large enough for the node count, or whether
    # the subnet is the binding constraint rather than the instance size.
    usable_ips_per_private_subnet = module.network.inventory.usable_ips_per_subnet
  }
}
