# These outputs are the contract between seed and everything else. Later layers
# and the workflows read them rather than hardcoding, so a value can never be
# copied by hand and then drift.

output "state_bucket" {
  description = "Goes in the `bucket` field of every other layer's backend config."
  value       = aws_s3_bucket.state.id
}

output "state_lock_mode" {
  description = "\"s3\" means backends set use_lockfile = true and there is no lock table."
  value       = var.state_lock_mode
}

output "state_lock_table" {
  description = "DynamoDB lock table name, or null when S3-native locking is used."
  value       = var.state_lock_mode == "dynamodb" ? aws_dynamodb_table.lock[0].name : null
}

output "github_oidc_provider_arn" {
  description = "Whether created here or referenced, the provider the pipeline federates through."
  value       = local.github_oidc_arn
}

output "bootstrap_pipeline_role_arn" {
  description = <<-EOT
    Set as the GitHub Actions repository VARIABLE `AWS_BOOTSTRAP_ROLE_ARN`.

    A variable, not a secret: a role ARN is not confidential, and treating
    non-secrets as secrets makes the real secrets harder to audit. What protects
    this role is its trust policy, not the obscurity of its name.
  EOT
  value       = aws_iam_role.bootstrap_pipeline.arn
}

output "management_account_id" {
  description = "Recorded so a later layer can assert it is pointed at the right account."
  value       = local.account_id
}

output "region" {
  description = "Set as the GitHub Actions repository variable `AWS_REGION`."
  value       = var.region
}

output "trusted_github_subject" {
  description = "The exact `sub` claim permitted to assume the pipeline role. Emitted so a trust failure can be diagnosed by comparing it against the token's actual claim."
  value       = local.github_sub_main
}
