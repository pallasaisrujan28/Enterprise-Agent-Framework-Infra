# The public interface of this layer. The account-baseline layer reads these via
# terraform_remote_state, so account ids are never copied by hand.

output "ou_id" {
  description = "The Workloads OU id. SCPs and baselines attach to this."
  value       = aws_organizations_organizational_unit.workloads.id
}

output "ou_arn" {
  description = "The OU ARN. Control Tower targets take ARNs, not ids — a difference that costs an hour the first time."
  value       = aws_organizations_organizational_unit.workloads.arn
}

output "account_ids" {
  description = "Account name to id. The account-baseline layer iterates this to build a provider per account."
  value       = { for k, v in aws_organizations_account.this : k => v.id }
}

output "account_arns" {
  description = "Account name to ARN."
  value       = { for k, v in aws_organizations_account.this : k => v.arn }
}

output "account_environments" {
  description = "Account name to environment label, so the baseline layer can vary log retention and gating by environment."
  value       = { for k, v in var.accounts : k => v.environment }
}

output "cross_account_role_arns" {
  description = <<-EOT
    The role in each new account that the bootstrap pipeline assumes to configure it.

    Created automatically by AWS Organizations at account creation, trusting the
    management account. This is why the account-baseline layer needs no stored
    credentials for the accounts it configures.
  EOT
  value = {
    for k, v in aws_organizations_account.this :
    k => "arn:${local.partition}:iam::${v.id}:role/OrganizationAccountAccessRole"
  }
}

output "guardrail_policy_id" {
  description = "Our SCP. One policy holding five statements, because AWS caps policies-per-target at five and Control Tower already uses part of that budget."
  value       = aws_organizations_policy.workloads_guardrails.id
}

output "control_tower_enrolled" {
  description = "Whether the OU was registered with Control Tower and therefore inherits its 16 controls."
  value       = var.enroll_in_control_tower
}
