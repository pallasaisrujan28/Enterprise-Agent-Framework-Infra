output "cluster_name" {
  description = "Cluster name. `lab/apps` reads this from this directory's state file."
  value       = module.eks_cluster.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks_cluster.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle for the API server."
  value       = module.eks_cluster.certificate_authority_data
}

output "region" {
  description = "Region, so lab/apps does not restate it."
  value       = var.region
}

output "account_id" {
  description = "Account the cluster lives in."
  value       = data.aws_caller_identity.current.account_id
}

output "vpc_id" {
  description = "VPC id."
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets the nodes run in."
  value       = module.network.private_subnet_ids
}

output "node_role_arn" {
  description = "Node role ARN. Anything a pod needs AWS access for can be attached here rather than given its own role."
  value       = aws_iam_role.node.arn
}

output "kubeconfig_command" {
  description = "Run this, then kubectl works. No --role-arn needed: your own SSO role is the cluster admin."
  value       = "aws eks update-kubeconfig --name ${module.eks_cluster.name} --region ${var.region}"
}

output "next_step" {
  description = "What to do once this has applied."
  value       = "cd ../apps && terraform init && terraform apply"
}

output "lab_inventory" {
  description = "One structured record of this layer, for review without reading the plan."
  value = {
    cluster_name       = module.eks_cluster.name
    kubernetes_version = var.kubernetes_version
    region             = var.region
    account_id         = data.aws_caller_identity.current.account_id

    nodes = {
      instance_types = var.instance_types
      count          = var.node_count
      disk_gib       = var.node_disk_size

      # Prefix delegation raises the per-node pod ceiling from 58 to the kubelet's 110. The
      # memory and RL stack is many small pods, so this decides whether it fits.
      pod_ceiling_per_node = 110
      prefix_delegation    = true
    }

    access = {
      # Deliberate, and the reason kubectl works from a laptop with no bastion.
      endpoint_public        = true
      public_access_cidrs    = ["0.0.0.0/0"]
      cluster_admin          = local.operator_role_arn_flat
      requires_role_arn_flag = false
    }

    # Stated because a local state file is the one thing here that can lose you a cluster.
    state = {
      backend               = "local"
      file                  = "lab/cluster/terraform.tfstate"
      losing_it_orphans_aws = true
      recovery              = "make teardown-check — reads AWS directly, not state"
    }

    cost_per_hour_usd = {
      control_plane = 0.10
      nodes         = 0.222 * var.node_count
      nat_gateway   = 0.05
      total_approx  = 0.10 + (0.222 * var.node_count) + 0.05
    }
  }
}
