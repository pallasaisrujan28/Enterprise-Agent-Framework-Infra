output "workload_ci_role_arn" {
  description = "Set this as AWS_ROLE_ARN in the workload repository's GitHub Actions variables."
  value       = module.baseline.workload_ci_role_arn
}

output "workload_boundary_arn" {
  description = "Permissions boundary ARN. Attach to any role the workload CI creates."
  value       = module.baseline.workload_boundary_arn
}
