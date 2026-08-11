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

variable "github_repository_owner_id" {
  description = <<-EOT
    The GitHub account's numeric id, which appears in the OIDC token's `sub` claim.

    Needed because GitHub changed the default subject format. Repositories created
    after 2026-07-15 get immutable numeric ids embedded in `sub`:

        repo:<owner>@<owner_id>/<repo>@<repository_id>

    Get it from the repository itself, or from a token:

        gh api repos/<owner>/<repo> --jq .owner.id

    Do not guess this. A wrong value produces "Not authorized to perform
    sts:AssumeRoleWithWebIdentity" with no indication of which condition missed.
  EOT
  type        = string
  default     = "194785418"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_owner_id))
    error_message = "github_repository_owner_id must be numeric."
  }
}

variable "github_repository_id" {
  description = <<-EOT
    The repository's numeric id, which appears in the OIDC token's `sub` claim.

        gh api repos/<owner>/<repo> --jq .id

    Immutable and never reused. That is the point of the change: renaming,
    transferring, or deleting and recreating the repository does NOT carry the old
    trust across. Under the older name-based format, a deleted repository's name
    could be claimed by someone else and inherit its AWS access.
  EOT
  type        = string
  default     = "1324052608"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be numeric."
  }
}

# NOTE: there is no `github_branch` variable.
#
# An earlier version pinned the single admin role to `refs/heads/main`. Removed
# because a branch name is the wrong control for an apply. Reaching main proves the
# change was reviewed and merged; it does not prove anyone approved THIS run. The
# apply gate is now the GitHub Environment below, and the plan role trusts any
# branch because it is read-only.

variable "github_apply_environment" {
  description = <<-EOT
    The GitHub Environment whose approval is required before an apply can reach
    AWS.

    This exact name goes inside the apply role's trust policy, so a job can only
    assume that role if it declares `environment:` with the same value. Rename it
    here and the workflow must be renamed in the same commit, or apply stops
    working.

    CREATED BY HAND IN GITHUB:

      Settings > Environments > New environment > this name
        - Required reviewers: at least one person
        - Deployment branches: selected branches, `main` only

    By hand is a CHOICE, not a limitation. An earlier version of this comment said
    Terraform cannot create it, which is wrong. The AWS provider cannot, but the
    GitHub provider's `github_repository_environment` can, including reviewers and
    branch policy. Not used because it needs a GitHub token with repository admin
    rights, which is a new long-lived secret to store and rotate — trading one
    problem for another to automate a five-minute task done once.

    Until reviewers are configured the Environment exists but approves nothing. AWS
    can only check that the run happened in an Environment of this name; it cannot
    check that anyone had to click approve. That half is yours to enforce.
  EOT
  type        = string
  default     = "bootstrap-apply"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,64}$", var.github_apply_environment))
    error_message = "github_apply_environment must be 1-64 chars of letters, digits, hyphen or underscore."
  }
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
