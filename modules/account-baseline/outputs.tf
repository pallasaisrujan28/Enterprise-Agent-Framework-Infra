output "workload_ci_role_arn" {
  description = "ARN of the workload CI role. Set this as a repo variable in GitHub Actions for workload pipelines."
  value       = aws_iam_role.workload_ci.arn
}

output "workload_boundary_arn" {
  description = "ARN of the permissions boundary policy. Attach this to any role created by the workload CI."
  value       = aws_iam_policy.workload_boundary.arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider in this account."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID for this account."
  value       = aws_guardduty_detector.this.id
}

output "workload_boundary_name" {
  description = "Name of the permissions boundary policy. Callers that must express the boundary as a policy ARN inside a policy document need the name, because the ARN is not knowable before the policy exists."
  value       = aws_iam_policy.workload_boundary.name
}

output "inventory" {
  description = "Structured record of this baseline, for cross-layer inventory and review."
  value = {
    account_id  = local.account_id
    partition   = local.partition
    environment = var.environment
    org_prefix  = var.org_prefix
    region      = var.region

    # Names are reported as generated, not as literals, so `make iam-inventory` and a
    # reviewer see the same strings the apply will use.
    workload_boundary = {
      name = local.boundary_name
      arn  = local.boundary_arn
    }
    workload_ci_role = {
      name = local.ci_role_name
    }
    budget = {
      name      = local.budget_name
      limit_usd = var.budget_limit_usd
    }
    github_oidc = {
      issuer_url  = var.github_oidc_issuer_url
      issuer_host = local.github_oidc_issuer_host
      subject     = local.github_sub_any_branch
    }
  }
}
