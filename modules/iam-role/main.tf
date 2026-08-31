# THE ONLY WAY A ROLE IS CREATED IN THIS REPOSITORY.
#
# No root module writes `resource "aws_iam_role"` directly. One creation path means
# a convention added here applies everywhere, retroactively, on the next apply.

locals {
  name = "${var.org_prefix}-${var.environment}-${var.layer}-${var.purpose}-role"

  # Mandatory tags. The caller cannot override these — extra_tags is merged FIRST
  # so the generated set wins on key collision.
  mandatory_tags = {
    ManagedBy       = "terraform"
    ManagedByModule = "modules/iam-role"
    OrgPrefix       = var.org_prefix
    Environment     = var.environment
    Layer           = var.layer
    Purpose         = var.purpose
    Owner           = var.owner
    TrustType       = var.trust.type
    Boundary        = var.boundary_arn == null ? "EXEMPT" : "enforced"
  }

  tags = merge(var.extra_tags, local.mandatory_tags)

  # ── Trust policy construction ───────────────────────────────────────────────
  #
  # Built with jsonencode rather than aws_iam_policy_document, because the four
  # trust shapes need different principal types and condition keys, and a data
  # source with dynamic blocks for that is harder to read than the JSON it emits.

  gh = var.trust.github_oidc

  # repo segment: immutable form embeds owner and repository IDs, separated by @
  # because @ cannot appear in a GitHub username or repository name.
  gh_repo_segment = local.gh == null ? "" : (
    coalesce(try(local.gh.immutable_subject, true), true)
    ? "${local.gh.owner}@${local.gh.owner_id}/${local.gh.repository}@${local.gh.repository_id}"
    : "${local.gh.owner}/${local.gh.repository}"
  )

  gh_subjects = local.gh == null ? [] : [
    for c in local.gh.contexts : "repo:${local.gh_repo_segment}:${c}"
  ]

  irsa = var.trust.eks_irsa

  assume_role_statements = {
    github_oidc = local.gh == null ? [] : [{
      Sid       = "GitHubOIDC"
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.gh.oidc_provider_arn }
      Condition = {
        # aud is checked with StringEquals: it is a single expected value.
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # sub is checked with StringLike because a context may contain a wildcard
        # (for example ref:refs/heads/* ). Where no wildcard is present StringLike
        # behaves as an exact match, so this is not a widening.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = local.gh_subjects
        }
      }
    }]

    eks_irsa = local.irsa == null ? [] : [{
      Sid       = "EKSServiceAccount"
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.irsa.oidc_provider_arn }
      Condition = {
        StringEquals = {
          # Both conditions, always. An IRSA trust policy with :sub but no :aud is
          # broader than intended, so the module does not let a caller omit it.
          "${local.irsa.oidc_issuer_host}:sub" = "system:serviceaccount:${local.irsa.namespace}:${local.irsa.service_account}"
          "${local.irsa.oidc_issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]

    aws_service = var.trust.aws_service == null ? [] : [{
      Sid       = "ServicePrincipal"
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = var.trust.aws_service.service_principals }
    }]

    account_principal = var.trust.account_principal == null ? [] : [{
      Sid       = "AccountPrincipal"
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = var.trust.account_principal.principal_arns }
    }]
  }

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.assume_role_statements[var.trust.type]
  })

  # ── Scoped PassRole ─────────────────────────────────────────────────────────
  pass_role_policy = length(var.pass_role_arns) == 0 ? {} : {
    "scoped-pass-role" = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid      = "PassOnlyTheseRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = var.pass_role_arns
      }]
    })
  }

  all_inline_policies = merge(var.inline_policies, local.pass_role_policy)
}

resource "aws_iam_role" "this" {
  name        = local.name
  description = var.description

  assume_role_policy   = local.assume_role_policy
  permissions_boundary = var.boundary_arn
  max_session_duration = var.max_session_duration

  # NOT set: `inline_policy` and `managed_policy_arns`. Both are deprecated on
  # this resource in favour of aws_iam_role_policy and
  # aws_iam_role_policy_attachment, and mixing them with the standalone resources
  # causes resource cycling.

  force_detach_policies = true

  tags = local.tags

  lifecycle {
    precondition {
      condition = var.boundary_arn != null || var.boundary_exemption_reason != null
      error_message = join(" ", [
        "Role ${local.name} has no permissions boundary and no exemption reason.",
        "A boundary grants nothing and only subtracts, so omitting one is never a",
        "way to widen permissions — but it does remove the cap. State a reason if",
        "that is intended."
      ])
    }
  }
}

resource "aws_iam_role_policy" "inline" {
  for_each = local.all_inline_policies

  name   = each.key
  role   = aws_iam_role.this.id
  policy = each.value
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

# ── Exclusivity: what makes drift self-correcting ─────────────────────────────
#
# These two resources make Terraform the exclusive manager of the role's policies.
# A policy attached out-of-band — the "add one thing to fix an incident" pattern
# that produced the untracked role set — is removed on the next apply.
#
# Reconciliation happens on apply, not continuously. That is a real limitation and
# the reason `make iam-orphans` exists as well: this catches unmanaged policies on
# a managed role, the orphan check catches unmanaged roles.

resource "aws_iam_role_policies_exclusive" "this" {
  count = var.exclusive_policy_management ? 1 : 0

  role_name    = aws_iam_role.this.name
  policy_names = [for k, _ in local.all_inline_policies : k]

  depends_on = [aws_iam_role_policy.inline]
}

resource "aws_iam_role_policy_attachments_exclusive" "this" {
  count = var.exclusive_policy_management ? 1 : 0

  role_name   = aws_iam_role.this.name
  policy_arns = var.managed_policy_arns

  depends_on = [aws_iam_role_policy_attachment.managed]
}
