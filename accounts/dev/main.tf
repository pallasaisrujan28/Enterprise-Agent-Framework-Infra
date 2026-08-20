# EAF-DEV ACCOUNT BASELINE
#
# Applies inside EAF-DEV (718438899462) via OrganizationAccountAccessRole.
# Run AFTER org-structure has created the account and Control Tower has
# finished enrolling it (CT creates CloudTrail and Config — do not duplicate).
#
# Apply with: apply-baseline workflow, target=dev

module "baseline" {
  source = "../../modules/account-baseline"

  account_name = "EAF-DEV"
  environment  = "dev"
  region       = var.region

  # Workload CI: the repository whose GitHub Actions can deploy to this account.
  # Update this when the application repository is known.
  github_repository          = "pallasaisrujan28/Enterprise-Agent-Framework-Infra"
  github_repository_owner_id = "194785418"
  github_repository_id       = "1324052608"

  budget_limit_usd   = 200
  budget_alert_email = "s.palla@reply.com"
}
