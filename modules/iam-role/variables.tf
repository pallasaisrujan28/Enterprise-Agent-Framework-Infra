# ── Identity: these four compose the role name ────────────────────────────────
#
# name = "${org_prefix}-${environment}-${layer}-${purpose}-role"
#
# The name is generated, never passed in. Reading a role name in the console
# therefore tells you the organisation, the environment, the layer that owns it
# and what it is for — which is the property this repository lost when three
# different naming schemes accumulated across five directories.

variable "org_prefix" {
  description = "Organisation prefix, e.g. \"eaf\". No default: it is an organisation-wide fact and must be supplied by the caller."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,11}$", var.org_prefix))
    error_message = "org_prefix must be 2-12 characters, lowercase alphanumeric, starting with a letter."
  }
}

variable "environment" {
  description = "Environment this role belongs to. \"management\" is for roles in the org management account, which has no workload environment."
  type        = string

  validation {
    condition     = contains(["management", "dev", "test", "staging", "prod"], var.environment)
    error_message = "environment must be one of: management, dev, test, staging, prod."
  }
}

variable "layer" {
  description = "The Terraform layer that owns this role. This is the locator: it names the directory a reader should open to find the declaration."
  type        = string

  validation {
    condition = contains([
      "bootstrap", "accounts", "platform", "cluster-addons", "apps"
    ], var.layer)
    error_message = "layer must be one of: bootstrap, accounts, platform, cluster-addons, apps."
  }
}

variable "purpose" {
  description = "What the role is for, in kebab-case, e.g. \"deployer\", \"node\", \"agent\", \"ebs-csi\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.purpose))
    error_message = "purpose must be kebab-case, 3-32 characters, starting with a letter and ending alphanumeric."
  }
}

variable "description" {
  description = "Why this role exists. Required, and must be a sentence rather than a label — an undescribed role is how the set became untrackable."
  type        = string

  validation {
    condition     = length(trimspace(var.description)) >= 20
    error_message = "description must be at least 20 characters. Say what assumes this role and why it needs to."
  }
}

variable "owner" {
  description = "Team or person accountable for this role, e.g. \"platform-team\". Surfaced as a tag and in the inventory."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

# ── Permissions boundary ──────────────────────────────────────────────────────
#
# Required, with a loud opt-out rather than a silent default.
#
# A boundary is an intersection and grants nothing: the effective permissions are
# the intersection of the identity policy and the boundary, so a boundary that
# omits a service denies it regardless of what the attached policy allows. This is
# the single most expensive IAM fact in this repository — attaching the WORKLOAD
# boundary to a DEPLOYER role would deny eks:*, ec2:* and
# iam:CreateOpenIDConnectProvider by omission, and fail naming the action rather
# than the boundary.
#
# So the caller must either supply a boundary or state in writing why not.

variable "boundary_arn" {
  description = "ARN of the permissions boundary policy. Pass an attribute reference (aws_iam_policy.x.arn), never a constructed string — a string creates no dependency edge, so Terraform cannot order the policy before the role. Set to null only with boundary_exemption_reason."
  type        = string
  default     = null
}

variable "boundary_exemption_reason" {
  description = "Required if boundary_arn is null. Explains why this role has no boundary. Exists so an unboundaried role is a deliberate, reviewable statement rather than an omission."
  type        = string
  default     = null

  validation {
    condition = (
      (var.boundary_arn == null) != (var.boundary_exemption_reason == null)
    )
    error_message = "Set exactly one of boundary_arn or boundary_exemption_reason. A role with neither is an unreviewed gap; a role with both is ambiguous."
  }

  validation {
    condition = (
      var.boundary_exemption_reason == null ||
      length(trimspace(coalesce(var.boundary_exemption_reason, ""))) >= 20
    )
    error_message = "boundary_exemption_reason must be at least 20 characters."
  }
}

# ── Trust policy ──────────────────────────────────────────────────────────────
#
# A tagged union. Terraform has no union type, so `type` selects which payload
# must be present and a validation enforces the pairing.
#
# The two payloads that exist because they are where this repository has actually
# lost time:
#
#   github_oidc — the sub claim is MUTUALLY EXCLUSIVE by job context. GitHub
#     documents that the `ref:` form applies only when the job does not reference
#     an environment and was not triggered by a pull request. Adding
#     `environment: dev` REPLACES the ref segment; it does not append. A trust
#     policy matching only ref:refs/heads/* rejects such a job. So the caller
#     names contexts explicitly and cannot express the broken combination by
#     accident.
#
#   eks_irsa — both the :sub and :aud conditions are emitted, always. Omitting
#     :aud is a documented way to make an IRSA trust policy far broader than
#     intended, so it is not the caller's decision.

variable "trust" {
  description = "Who may assume this role. Set `type` and exactly the matching payload."

  type = object({
    type = string

    github_oidc = optional(object({
      oidc_provider_arn = string
      owner             = string
      repository        = string
      owner_id          = optional(string)
      repository_id     = optional(string)
      immutable_subject = optional(bool, true)
      contexts          = list(string)
    }))

    eks_irsa = optional(object({
      oidc_provider_arn = string
      oidc_issuer_host  = string
      namespace         = string
      service_account   = string
    }))

    aws_service = optional(object({
      service_principals = list(string)
    }))

    account_principal = optional(object({
      principal_arns = list(string)
    }))
  })

  validation {
    condition = contains(
      ["github_oidc", "eks_irsa", "aws_service", "account_principal"],
      var.trust.type
    )
    error_message = "trust.type must be one of: github_oidc, eks_irsa, aws_service, account_principal."
  }

  validation {
    condition = length(compact([
      var.trust.github_oidc == null ? "" : "github_oidc",
      var.trust.eks_irsa == null ? "" : "eks_irsa",
      var.trust.aws_service == null ? "" : "aws_service",
      var.trust.account_principal == null ? "" : "account_principal",
    ])) == 1
    error_message = "Provide exactly one trust payload."
  }

  validation {
    condition = (
      var.trust.type == "github_oidc" ? var.trust.github_oidc != null :
      var.trust.type == "eks_irsa" ? var.trust.eks_irsa != null :
      var.trust.type == "aws_service" ? var.trust.aws_service != null :
      var.trust.account_principal != null
    )
    error_message = "The supplied trust payload must match trust.type."
  }

  # Immutable subject claims: repositories created after 15 July 2026 use a `sub`
  # of the form repo:OWNER@OWNER_ID/REPO@REPO_ID:CONTEXT, and the IDs cannot be
  # removed. A trust policy written in the older repo:OWNER/REPO form silently
  # never matches — no error, just a failed AssumeRoleWithWebIdentity. This
  # repository uses the immutable format, so the IDs are required when it is on.
  validation {
    condition = (
      var.trust.github_oidc == null ||
      coalesce(try(var.trust.github_oidc.immutable_subject, true), true) == false ||
      (
        try(var.trust.github_oidc.owner_id, null) != null &&
        try(var.trust.github_oidc.repository_id, null) != null
      )
    )
    error_message = "github_oidc with immutable_subject = true requires owner_id and repository_id. They appear in the sub claim and cannot be omitted."
  }

  # Reject the shapes that do not exist. A bare branch name is the most common
  # mistake, and it fails at assume-role time with no useful message.
  validation {
    condition = (
      var.trust.github_oidc == null ||
      alltrue([
        for c in var.trust.github_oidc.contexts :
        c == "*" ||
        c == "pull_request" ||
        startswith(c, "environment:") ||
        startswith(c, "ref:refs/heads/") ||
        startswith(c, "ref:refs/tags/") ||
        startswith(c, "job_workflow_ref:")
      ])
    )
    error_message = "Each github_oidc context must be one of: \"pull_request\", \"environment:NAME\", \"ref:refs/heads/BRANCH\", \"ref:refs/tags/TAG\", \"job_workflow_ref:...\", or \"*\". A bare branch name is not a valid subject context."
  }

  validation {
    condition = (
      var.trust.github_oidc == null ||
      length(var.trust.github_oidc.contexts) > 0
    )
    error_message = "github_oidc requires at least one context. An unconditioned OIDC trust policy would let any repository assume this role."
  }

  validation {
    condition = (
      var.trust.eks_irsa == null ||
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.trust.eks_irsa.namespace))
    )
    error_message = "eks_irsa.namespace must be a valid Kubernetes namespace name."
  }
}

# ── Policies ──────────────────────────────────────────────────────────────────

variable "managed_policy_arns" {
  description = "Managed policy ARNs to attach. Attached with aws_iam_role_policy_attachment, not the deprecated managed_policy_arns argument on aws_iam_role."
  type        = list(string)
  default     = []
}

variable "inline_policies" {
  description = "Inline policies as a map of name => JSON document. Created with aws_iam_role_policy, not the deprecated inline_policy block."
  type        = map(string)
  default     = {}
}

variable "pass_role_arns" {
  description = "Role ARNs this role may pass to an AWS service. Generates a scoped iam:PassRole policy. Never wildcarded: a deployer missing PassRole fails with an error about the target role, not about PassRole, which is a slow thing to diagnose."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.pass_role_arns, "*")
    error_message = "pass_role_arns must not contain \"*\". List the role ARNs explicitly."
  }
}

variable "exclusive_policy_management" {
  description = "Make Terraform the exclusive manager of this role's inline policies and managed-policy attachments. An attachment added out-of-band is removed on the next apply, which is what stops the role set drifting."
  type        = bool
  default     = true
}

# ── Session and tagging ───────────────────────────────────────────────────────

variable "max_session_duration" {
  description = "Maximum session duration in seconds. AWS permits 3600-43200."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200 seconds."
  }
}

variable "extra_tags" {
  description = "Additional tags. The mandatory set is generated and cannot be overridden."
  type        = map(string)
  default     = {}
}
