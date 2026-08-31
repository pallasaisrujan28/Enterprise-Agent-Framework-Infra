variable "org_prefix" {
  description = "Short organisation prefix for every generated name, e.g. `eaf`. Required — a module that assumes an organisation's name is not reusable."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.org_prefix))
    error_message = "org_prefix must be lowercase, 2-12 characters, starting with a letter."
  }
}

variable "account_name" {
  description = "The AWS account name, used for tagging and naming."
  type        = string
}

variable "environment" {
  description = "dev | test | staging | prod"
  type        = string
  validation {
    condition     = contains(["dev", "test", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, staging, prod"
  }
}

variable "github_repository" {
  description = "owner/repo permitted to assume the workload CI role, e.g. pallasaisrujan28/my-app."
  type        = string
}

variable "github_repository_owner_id" {
  description = "Numeric GitHub owner ID — appears in the OIDC sub claim for immutable-subject tokens."
  type        = string
  # No default. This is a per-organisation fact, and the previous default silently
  # applied one organisation's ID to any caller that forgot it — producing a trust
  # policy that never matches, with no error at plan or apply time.
}

variable "github_oidc_issuer_url" {
  description = "GitHub's OIDC issuer URL. Override only for GitHub Enterprise Server, whose issuer is the appliance host."
  type        = string
  default     = "https://token.actions.githubusercontent.com"
  validation {
    condition     = startswith(var.github_oidc_issuer_url, "https://")
    error_message = "github_oidc_issuer_url must include the https:// scheme, which aws_iam_openid_connect_provider requires."
  }
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID — appears in the OIDC sub claim for immutable-subject tokens."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly budget threshold in USD. Alerts fire at 80% and 100%."
  type        = number
  default     = 100
}

variable "budget_alert_email" {
  description = "Email address for budget alert notifications."
  type        = string
}

variable "region" {
  description = "AWS region for account-level resources. Used in the Security Hub standards ARN, which is region-qualified."
  type        = string
  # No default. A module that guesses its own region is not portable, and the guess
  # is invisible at the call site: a caller in us-east-1 who omits it gets a Security
  # Hub subscription ARN pointing at another region.
}

# ── A note on the provider constraint in main.tf ──────────────────────────────
#
# It is ">= 5.0.0", not ">= 6.0.0". The defect being fixed is the *shape* — a
# pessimistic "~> 5.0" inside a module forbids the caller from selecting a newer
# major, which is the root module's decision and its lock file's job to pin.
#
# Raising the floor to 6.x is a separate change with a different risk profile:
# accounts/dev and accounts/prod are live, neither commits a lock file, and a
# provider major upgrade wants a reviewed plan against real state. Doing both at once
# would hide a behavioural change inside a rename.
