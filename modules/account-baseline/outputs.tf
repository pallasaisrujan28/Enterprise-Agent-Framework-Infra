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
