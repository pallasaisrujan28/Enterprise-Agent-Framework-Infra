# PER-ACCOUNT BASELINE
#
# Runs inside each member account via OrganizationAccountAccessRole.
# Applied AFTER the account exists and Control Tower has finished enrolling it.
#
# What CT already creates (do not duplicate — conflicts or double billing):
#   CloudTrail   org-level trail, all regions
#   Config       recorder and delivery channel
#   IAM roles    AWSControlTowerExecution, AWSControlTowerReadOnly, etc.
#
# What this layer adds:
#   S3 public access block   CT prevents weakening it; this ensures it is ON
#   GuardDuty                per-account detector (no delegated admin in shared org)
#   Security Hub             aggregates GuardDuty + Config; FSBP standard
#   Permissions boundary     caps what the workload CI role can do
#   GitHub OIDC provider     one per account, for workload pipelines
#   Workload CI role         GitHub Actions in app repos assumes this to deploy
#   Budget alert             monthly cost notification

data "aws_caller_identity" "this" {}
data "aws_partition" "this" {}

locals {
  account_id = data.aws_caller_identity.this.account_id
  partition  = data.aws_partition.this.partition

  # Immutable OIDC subject prefix — same format as bootstrap/seed/iam.tf.
  repo_owner = split("/", var.github_repository)[0]
  repo_name  = split("/", var.github_repository)[1]
  github_sub_any_branch = "repo:${local.repo_owner}@${var.github_repository_owner_id}/${local.repo_name}@${var.github_repository_id}:ref:refs/heads/*"
}

# ── S3 account-level public access block ─────────────────────────────────────
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── GuardDuty ─────────────────────────────────────────────────────────────────
resource "aws_guardduty_detector" "this" {
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
  }
}

# ── Security Hub ──────────────────────────────────────────────────────────────
resource "aws_securityhub_account" "this" {
  # auto_enable_controls = true so new controls in the standard are enabled
  # automatically rather than requiring a manual opt-in each time AWS adds one.
  auto_enable_controls = true
  enable_default_standards = false
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:${local.partition}:securityhub:${var.region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.this]
}

# ── Permissions boundary ──────────────────────────────────────────────────────
#
# Allowlist-based: only the services the agent platform actually uses.
# The SCP above already applies a ceiling on the whole account. The boundary
# adds a second ceiling specifically on CI-created roles, preventing escalation:
# the CI role can create Lambda execution roles, but only if those roles also
# carry this boundary. A role created without the boundary condition fails at
# creation time, not at runtime.
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid    = "AllowWorkloadServices"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "lambda:*",
      "s3:*",
      "apigateway:*",
      "logs:*",
      "cloudwatch:*",
      "xray:*",
      "ssm:GetParameter*",
      "ssm:DescribeParameters",
      "secretsmanager:GetSecretValue",
      "ecr:*",
      "ecs:*",
      "dynamodb:*",
      "sqs:*",
      "sns:*",
      "events:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowIAMWithBoundary"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:DeleteRole",
      "iam:PassRole",
      "iam:GetRole",
      "iam:ListRoles",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = ["arn:${local.partition}:iam::${local.account_id}:policy/eaf-workload-boundary"]
    }
  }

  statement {
    sid    = "DenyBoundaryRemoval"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:policy/eaf-workload-boundary"]
  }

  statement {
    sid    = "DenyOrgAndSecurityActions"
    effect = "Deny"
    actions = [
      "organizations:*",
      "account:CloseAccount",
      "guardduty:DeleteDetector",
      "securityhub:DisableSecurityHub",
      "config:StopConfigurationRecorder",
      "cloudtrail:StopLogging",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "eaf-workload-boundary"
  description = "Permissions boundary for workload CI roles. Caps what any CI-created role can do."
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

# ── GitHub OIDC provider ──────────────────────────────────────────────────────
#
# One per account. AWS allows exactly one OIDC provider per URL per account.
# The bootstrap layers create one in the management account; member accounts
# each need their own.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # No thumbprint_list — AWS validates GitHub's certificate against its own
  # trusted CA store for this provider. Pinning a thumbprint causes outages
  # when GitHub rotates its certificate.
}

# ── Workload CI role ──────────────────────────────────────────────────────────
#
# GitHub Actions in workload repositories assumes this role to deploy.
# Trust is limited to branch pushes in the configured repository — the
# same immutable-subject OIDC pattern as the bootstrap pipeline roles.
# The permissions boundary ensures this role cannot escalate beyond the
# workload service allowlist even if given a permissive identity policy.
data "aws_iam_policy_document" "workload_ci_trust" {
  statement {
    sid     = "GitHubActionsWorkloadBranches"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_sub_any_branch]
    }
  }
}

resource "aws_iam_role" "workload_ci" {
  name                 = "eaf-workload-ci-role"
  description          = "Assumed by GitHub Actions in the workload repository to deploy to this account."
  assume_role_policy   = data.aws_iam_policy_document.workload_ci_trust.json
  max_session_duration = 3600

  permissions_boundary = aws_iam_policy.workload_boundary.arn
}

# ── Budget alert ──────────────────────────────────────────────────────────────
resource "aws_budgets_budget" "monthly" {
  name         = "eaf-${var.account_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
