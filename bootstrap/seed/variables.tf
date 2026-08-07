variable "org_prefix" {
  description = <<-EOT
    Prefixes every resource this repository creates, so the platform's resources
    are identifiable and so IAM policies can be scoped by name pattern.

    Lowercase: it lands in S3 bucket names, which cannot contain uppercase.
  EOT
  type        = string
  default     = "eaf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.org_prefix))
    error_message = "org_prefix must be lowercase alphanumeric with hyphens, starting with a letter, 2-16 chars."
  }
}

variable "management_account_id" {
  description = <<-EOT
    The organization's management account. Seed runs here and only here.

    Required with no default, deliberately. A default would let this apply
    somewhere else if the credential in the environment pointed elsewhere, and
    the whole point of pinning it is that the environment is not trustworthy.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account id."
  }
}

variable "region" {
  description = <<-EOT
    Home region for the state bucket and the pipeline role.

    London. Note that the permitted region SET for workloads is a separate
    concern, handled by SCP in the organization layer — this is only where seed's
    own resources live.
  EOT
  type        = string
  default     = "eu-west-2"
}

variable "github_repository" {
  description = <<-EOT
    The `owner/repo` permitted to assume the bootstrap pipeline role.

    This is the difference between "trust tokens signed by GitHub" and "trust
    tokens signed by GitHub FOR THIS REPOSITORY". Omitting the repository scope is
    the classic OIDC misconfiguration: it trusts every repository on GitHub.
  EOT
  type        = string
  default     = "pallasaisrujan28/Enterprise-Agent-Framework-Infra"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be in owner/repo form."
  }
}

variable "github_branch" {
  description = <<-EOT
    The only branch whose workflow runs may assume the bootstrap pipeline role.

    The role holds AdministratorAccess in the management account, so the trust
    condition is the control that matters. Scoped to one branch because a pull
    request from any branch — including one nobody has reviewed — must not be able
    to reach it.
  EOT
  type        = string
  default     = "main"
}

variable "create_oidc_provider" {
  description = <<-EOT
    Whether to create the GitHub OIDC provider, or reference an existing one.

    AWS permits exactly ONE provider per URL per account, and the provider is
    account-level shared infrastructure rather than something a project owns. So:

      true   no provider exists in this account. Create it.
      false  one already exists (another project, or the account baseline).
             Referenced as a data source. Do NOT import it — a later destroy here
             would remove a provider other pipelines depend on.

    Sharing it grants nothing. The provider only asserts that a token was signed
    by GitHub; which repository and which ref may assume a role is decided by that
    role's own trust condition.

    Verified empty in the management account at time of writing, so the default is
    true. Check before changing accounts:
        aws iam list-open-id-connect-providers
  EOT
  type        = bool
  default     = true
}

variable "state_lock_mode" {
  description = <<-EOT
    How Terraform state is locked. "s3" or "dynamodb".

    Default is "s3": S3-native locking became generally available in Terraform
    1.11 and the DynamoDB arguments in the S3 backend are now deprecated with
    removal signalled. That removes a table to create, pay for and grant access
    to.

    The implementation spec lists a DynamoDB lock table with "or use S3 native
    use_lockfile" as an alternative. This takes the alternative, because the
    DynamoDB path is the deprecated one — most published examples predate the
    change.

    Set to "dynamodb" only if something genuinely requires it.
  EOT
  type        = string
  default     = "s3"

  validation {
    condition     = contains(["s3", "dynamodb"], var.state_lock_mode)
    error_message = "state_lock_mode must be \"s3\" or \"dynamodb\"."
  }
}
