output "name" {
  description = "Cluster name. Pass as an attribute reference so dependants order correctly."
  value       = aws_eks_cluster.this.name
}

output "arn" {
  description = "Cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "endpoint" {
  description = "Kubernetes API endpoint. Needed to configure the kubernetes and helm providers in a later layer."
  value       = aws_eks_cluster.this.endpoint
}

output "certificate_authority_data" {
  description = "Base64 CA certificate for the API server. Pairs with `endpoint` to configure a Kubernetes client."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = <<-EOT
    The security group EKS creates and manages for control-plane-to-node traffic.

    Every managed node group joins it automatically. Add rules to it rather than
    building a parallel group, or you end up with two sources of truth for what can
    reach the nodes.
  EOT
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "kubernetes_version" {
  description = "The cluster's Kubernetes minor version, as reported by AWS."
  value       = aws_eks_cluster.this.version
}

output "platform_version" {
  description = "EKS platform version, e.g. `eks.4`. Some add-on and feature availability is gated on this rather than on the Kubernetes version."
  value       = aws_eks_cluster.this.platform_version
}

output "status" {
  description = "Cluster status. `ACTIVE` once the control plane is serving."
  value       = aws_eks_cluster.this.status
}

output "inventory" {
  description = "Structured record of this cluster, for cross-layer inventory and review."
  value = {
    name               = aws_eks_cluster.this.name
    arn                = aws_eks_cluster.this.arn
    kubernetes_version = aws_eks_cluster.this.version
    platform_version   = aws_eks_cluster.this.platform_version
    support_type       = var.support_type

    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access

    # Surfaced because a wide-open API endpoint is the single most consequential
    # setting here, and it should be answerable without reading the configuration.
    public_access_cidrs = var.endpoint_public_access ? var.public_access_cidrs : []
    publicly_reachable  = var.endpoint_public_access && contains(var.public_access_cidrs, "0.0.0.0/0")

    authentication_mode        = "API"
    secrets_encrypted_with_kms = var.secrets_kms_key_arn != null
    enabled_log_types          = var.enabled_cluster_log_types

    # Every cluster-admin grant, in one list. The implicit grant is named explicitly
    # when it is in play, because it is otherwise invisible.
    implicit_creator_admin = var.bootstrap_cluster_creator_admin_permissions
    administrators = concat(
      var.bootstrap_cluster_creator_admin_permissions ? ["IMPLICIT: whichever principal created the cluster"] : [],
      [
        for k, p in local.access_policies :
        var.access_entries[p.entry_key].principal_arn
        if endswith(p.policy_arn, "/AmazonEKSClusterAdminPolicy") && p.scope_type == "cluster"
      ],
    )

    access_entries = {
      for k, e in var.access_entries : k => {
        principal_arn = e.principal_arn
        type          = e.type
        policies = [
          for pk, p in local.access_policies : {
            policy_arn = p.policy_arn
            scope      = p.scope_type
            namespaces = p.scope_type == "namespace" ? p.namespaces : null
          } if p.entry_key == k
        ]
      }
    }
  }
}
