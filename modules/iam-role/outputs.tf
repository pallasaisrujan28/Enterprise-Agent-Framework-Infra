output "arn" {
  description = "Role ARN. Pass this as an attribute reference to consumers, never a reconstructed string."
  value       = aws_iam_role.this.arn
}

output "name" {
  description = "Generated role name."
  value       = aws_iam_role.this.name
}

output "unique_id" {
  description = "Stable unique id. Survives a rename, unlike the name or ARN."
  value       = aws_iam_role.this.unique_id
}

# ── The inventory record ──────────────────────────────────────────────────────
#
# Every layer aggregates these into one `iam_roles` output, and `make
# iam-inventory` collects those across layers into a single table. Generated from
# state, never hand-maintained, so it cannot disagree with what exists.
#
# This is one half of the answer to "we lost track of the roles". The other half is
# `make iam-orphans`, which finds roles that are NOT in any of these records.
output "inventory" {
  description = "Structured record of this role for the cross-layer IAM inventory."
  value = {
    name        = aws_iam_role.this.name
    arn         = aws_iam_role.this.arn
    unique_id   = aws_iam_role.this.unique_id
    description = var.description
    org_prefix  = var.org_prefix
    environment = var.environment
    layer       = var.layer
    purpose     = var.purpose
    owner       = var.owner
    trust_type  = var.trust.type

    boundary_arn              = var.boundary_arn
    boundary_exemption_reason = var.boundary_exemption_reason

    managed_policy_arns  = var.managed_policy_arns
    inline_policy_names  = sort([for k, _ in local.all_inline_policies : k])
    pass_role_arns       = var.pass_role_arns
    exclusive_management = var.exclusive_policy_management
    max_session_duration = var.max_session_duration

    # Flattened for human review: the exact subjects that may assume this role.
    # An over-broad trust policy is visible here without reading JSON.
    #
    # For eks_pod_identity the cluster scope is spelled out rather than left implicit,
    # because "any cluster in this account" is the default and is the one thing about
    # this trust type a reviewer must not have to infer.
    trusted_subjects = (
      var.trust.type == "github_oidc" ? local.gh_subjects :
      var.trust.type == "eks_irsa" ? ["system:serviceaccount:${local.irsa.namespace}:${local.irsa.service_account}"] :
      var.trust.type == "eks_pod_identity" ? [
        format(
          "system:serviceaccount:%s:%s (clusters: %s)",
          local.pid.namespace,
          local.pid.service_account,
          try(local.pid.cluster_names, null) == null ? "ANY in this account" : join(", ", local.pid.cluster_names),
        )
      ] :
      var.trust.type == "aws_service" ? var.trust.aws_service.service_principals :
      var.trust.account_principal.principal_arns
    )
  }
}
