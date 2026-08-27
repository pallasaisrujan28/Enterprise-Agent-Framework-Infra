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
  default     = "194785418"
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
  description = "AWS region for account-level resources."
  type        = string
  default     = "eu-west-2"
}
