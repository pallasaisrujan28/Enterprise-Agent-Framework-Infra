# EAF-PROD ACCOUNT BASELINE
#
# Applies inside EAF-PROD (679090980132) via OrganizationAccountAccessRole.
# Run AFTER org-structure has created the account and Control Tower has
# finished enrolling it (CT creates CloudTrail and Config — do not duplicate).
#
# Apply with: apply-baseline workflow, target=prod (requires approval)

module "baseline" {
  source = "../../modules/account-baseline"

  account_name  = "EAF-PROD"
  environment   = "prod"
  region        = var.region

  github_repository          = "pallasaisrujan28/Enterprise-Agent-Framework-Infra"
  github_repository_owner_id = "194785418"
  github_repository_id       = "1324052608"

  budget_limit_usd   = 500
  budget_alert_email = "s.palla@reply.com"
}
