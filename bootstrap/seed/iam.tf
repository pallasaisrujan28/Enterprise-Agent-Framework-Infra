# THE TWO PIPELINE ROLES.
#
# Two, not one, and the split is forced by how GitHub builds the token.
#
# Nothing is "mapped" anywhere. A role carries a trust policy, and AWS does string
# comparisons against claims in the signed token. The `sub` claim is the one that
# matters, and it CHANGES SHAPE depending on what triggered the run:
#
#   push to any branch      repo:<owner>/<repo>:ref:refs/heads/<branch>
#   pull request event      repo:<owner>/<repo>:pull_request
#   job with `environment:` repo:<owner>/<repo>:environment:<name>
#
# The workflow cannot set that value. GitHub writes it from the real run and signs
# it, which is the only reason AWS can believe it.
#
# A single role pinned to `refs/heads/main` therefore cannot be assumed from a
# feature branch AND cannot be assumed by a job that declares an environment. The
# second half is the trap: adding the manual-approval gate is what breaks it, so the
# failure arrives exactly when the control is added.
#
# Hence:
#
#   eaf-bootstrap-plan-role      ReadOnlyAccess.       Any branch.
#   eaf-bootstrap-pipeline-role  AdministratorAccess.  ONLY the approval gate.
#
# Branch protection is the other half of this and lives in GitHub, not AWS: main
# requires a pull request and cannot be pushed to directly. AWS only sees what the
# token says, so what makes `refs/heads/main` mean "reviewed" is that rule.

# THE CLAIM STRINGS THE TWO ROLES ACCEPT.
#
# Moved here from oidc.tf, where they read as if the OIDC provider knew about
# branches. It does not. The provider stores an issuer URL and an allowed audience,
# nothing else. Repository and branch scoping is a property of a ROLE.
#
# Anatomy of the value, since none of it is guessable:
#
#   repo:pallasaisrujan28/Enterprise-Agent-Framework-Infra:ref:refs/heads/*
#   └──┘ └──────────────┘ └──────────────────────────────┘ └──┘ └────────┘└┘
#    1          2                        3                   4       5     6
#
#   1  literal text, always present
#   2  the GitHub account
#   3  the repository
#   4  literal text meaning "a git ref follows"
#   5  git's namespace for branches (tags would be refs/tags/)
#   6  our wildcard
#
# GitHub writes the whole string from the real run and signs it. A workflow cannot
# set it. That signature is the only reason AWS can trust any of it.
locals {
  # Split rather than take owner and name as separate variables, so
  # `var.github_repository` stays the single place the repository is named.
  repo_owner = split("/", var.github_repository)[0]
  repo_name  = split("/", var.github_repository)[1]

  # THE IMMUTABLE SUBJECT PREFIX. Read this before changing anything here.
  #
  # Every published example, and the first version of this file, used:
  #
  #     repo:<owner>/<repo>
  #
  # That is WRONG for this repository, and the failure is a bare "Not authorized to
  # perform sts:AssumeRoleWithWebIdentity" with no hint as to which condition missed.
  #
  # GitHub changed the default subject format. Repositories created after
  # 2026-07-15 get immutable numeric IDs embedded in `sub`:
  #
  #     repo:<owner>@<owner_id>/<repo>@<repository_id>
  #
  # Measured from a real token rather than taken from documentation, because
  # `GET /repos/{owner}/{repo}/actions/oidc/customization/sub` reports
  # `use_immutable_subject: false` while the token uses the immutable form anyway.
  # The observed claim was:
  #
  #     repo:pallasaisrujan28@194785418/Enterprise-Agent-Framework-Infra@1324052608:ref:refs/heads/feature/bootstrap-organization
  #
  # This is a security improvement, not an inconvenience. The IDs are assigned once
  # and never reused, so renaming, transferring, or deleting and recreating the
  # repository does NOT keep the old trust. Under the name-based format, a deleted
  # repository's name could be claimed by someone else and inherit its access.
  #
  # See:
  #   https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/
  #   https://learn.microsoft.com/en-gb/entra/workload-id/workload-identities-github-immutable-subjects
  #
  # NOTE for GitHub Enterprise Server, which the rollout excludes: there the format
  # is still `repo:<owner>/<repo>`, so both IDs would need to be dropped from here.
  github_sub_prefix = "repo:${local.repo_owner}@${var.github_repository_owner_id}/${local.repo_name}@${var.github_repository_id}"

  # ANY BRANCH, for the read-only plan role.
  #
  # The `ref:refs/heads/` form rather than `pull_request`. Both would work, but the
  # pull-request claim carries no branch name. The ref form does, so the branch stays
  # visible in CloudTrail and available to any future narrowing.
  #
  # The wildcard's POSITION is the control. A trailing `*` on the whole prefix would
  # also match `:environment:<name>` and hand the approval-gated identity to any
  # branch. Keeping the literal `ref:refs/heads/` makes that impossible.
  github_sub_any_branch = "${local.github_sub_prefix}:ref:refs/heads/*"

  # The environment form, for the admin apply role. The strongest of the three,
  # because GitHub will not put an environment claim in a token unless the job
  # actually ran in that Environment. Where the Environment requires reviewers, the
  # claim is therefore evidence a human approved THIS run.
  #
  # Branch protection cannot prove that. It proves code reached main.
  github_sub_apply_environment = "${local.github_sub_prefix}:environment:${var.github_apply_environment}"
}

# WHY THIS CONDITIONS ON `sub` AND NOT ON `repository_id` DIRECTLY.
#
# The token also carries `repository_id` and `repository_owner_id` as separate claims,
# which would be tidier than parsing them out of a composite string.
#
# Not used, because the sources disagree on whether AWS accepts them as condition
# keys. GitHub's own AWS guide states custom OIDC claims are unsupported in AWS and
# recommends evaluating `token.actions.githubusercontent.com:sub`. Later reporting says
# AWS STS added provider-specific GitHub claims as condition keys.
#
# The cost of being wrong is not symmetric. An unrecognised condition key does not
# error — the statement simply never matches, so every run is denied and it presents
# as a trust bug rather than an unsupported feature. `sub` is agreed by both sources
# to work, and it is measured working here.
#
# Revisit only with a verified assume-role call, not with a documentation link.
#
# The permissions on the admin role cannot meaningfully be reduced — it creates
# accounts, OUs and SCPs, and no AWS-managed policy covers Organizations
# administration more narrowly. So THE TRUST POLICY IS THE CONTROL, and the control
# is that the only `sub` it accepts is one GitHub will not mint unless the job ran
# in a protected Environment.

# --------------------------------------------------------------------------
# PLAN ROLE — read-only, assumable from any branch in this repository.
# --------------------------------------------------------------------------
#
# Read-only is what makes it safe to expose to unreviewed branch code. A plan needs
# to read state and describe existing resources; it never needs to write.
#
# Worth being clear about what this does expose: anyone who can push a branch can
# read resource metadata in the management account through the plan output. That is a
# real trade, accepted because the alternative — no plan before merge — means changes
# get reviewed without anyone seeing their effect.
data "aws_iam_policy_document" "bootstrap_plan_trust" {
  statement {
    sid     = "GitHubActionsPlanFromAnyBranch"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    # Without the audience condition a token minted for a different audience could
    # be replayed here.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike, because the value ends in a wildcard covering every branch. That
    # is intended here: feature branches and main both need to plan, and the branch
    # name is not known in advance.
    #
    # The wildcard's POSITION is what keeps this safe. `repo:owner/repo:*` is the
    # standard OIDC mistake — it also matches `:environment:<name>`, so any branch
    # could obtain the approval-gated identity. Keeping the literal
    # `ref:refs/heads/` prefix means this value can only ever match a branch.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_sub_any_branch]
    }
  }
}

resource "aws_iam_role" "bootstrap_plan" {
  name        = "${var.org_prefix}-bootstrap-plan-role"
  description = "GitHub Actions assumes this to run `terraform plan`. Read-only. Trust limited to branches in ${var.github_repository}."

  assume_role_policy = data.aws_iam_policy_document.bootstrap_plan_trust.json

  # A plan is minutes, not hours. Short because there is no reason for it not to be.
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "bootstrap_plan_readonly" {
  role       = aws_iam_role.bootstrap_plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

# A plan also needs to WRITE the state lock, which ReadOnlyAccess does not cover.
#
# Not obvious, and it fails late: `terraform plan` reads fine, then errors acquiring
# the lock, which presents as a state problem rather than a permissions one.
#
# Scoped to the lock object only. The plan role can lock and unlock; it cannot write
# the state itself.
data "aws_iam_policy_document" "bootstrap_plan_state_lock" {
  statement {
    sid    = "ReadState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }

  statement {
    sid    = "HoldTheLockOnly"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    # `.tflock` only. Without the suffix restriction this would grant write access
    # to state itself, which would make "read-only" untrue.
    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "bootstrap_plan_state_lock" {
  name   = "state-read-and-lock"
  role   = aws_iam_role.bootstrap_plan.id
  policy = data.aws_iam_policy_document.bootstrap_plan_state_lock.json
}

# The plan role needs to assume OrganizationAccountAccessRole in member accounts
# so Terraform can plan the per-account baseline layers.
#
# Scoped to the role NAME only — any account in the organization. This is the
# least-privilege form available because member account IDs are not known at
# the time this policy is written (they are created by the org-structure layer
# after seed runs). ReadOnlyAccess alone does not include sts:AssumeRole.
data "aws_iam_policy_document" "bootstrap_plan_member_assume" {
  statement {
    sid    = "AssumeOrganizationAccountAccessRole"
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
    ]
    resources = [
      "arn:${local.partition}:iam::*:role/OrganizationAccountAccessRole",
    ]
  }
}

resource "aws_iam_role_policy" "bootstrap_plan_member_assume" {
  name   = "assume-organization-account-access-role"
  role   = aws_iam_role.bootstrap_plan.id
  policy = data.aws_iam_policy_document.bootstrap_plan_member_assume.json
}

# --------------------------------------------------------------------------
# APPLY ROLE — AdministratorAccess, reachable only through the approval gate.
# --------------------------------------------------------------------------
#
# The only accepted `sub` is the environment form. GitHub will not put an
# environment claim in a token unless the job actually ran in that Environment, and
# where the Environment requires reviewers, the claim is therefore PROOF that a
# human approved this specific run.
#
# That is stronger than branch protection, which proves only that code reached main.
#
# SETUP THIS DEPENDS ON, in GitHub repository settings:
#
#   Settings > Environments > New environment > "management"
#     - Required reviewers: at least one person
#     - Deployment branches: selected branches, `main` only
#
# Until that Environment exists with reviewers, the gate is not real. The trust
# policy cannot verify that reviewers are configured — only that the run happened in
# an Environment of that name.
data "aws_iam_policy_document" "bootstrap_pipeline_trust" {
  statement {
    sid     = "GitHubActionsApprovedEnvironmentOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Deliberately NOT including the main-branch form.
    #
    # Including it as well would mean any push to main gets AdministratorAccess with
    # no approval, which is the thing the gate exists to prevent. Keeping it "just in
    # case the environment is not set up yet" would make the gate decorative.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_sub_apply_environment]
    }
  }
}

resource "aws_iam_role" "bootstrap_pipeline" {
  name        = "${var.org_prefix}-bootstrap-pipeline-role"
  description = "GitHub Actions assumes this to apply bootstrap. Admin in the management account; trust is limited to the ${var.github_apply_environment} Environment in ${var.github_repository}."

  assume_role_policy = data.aws_iam_policy_document.bootstrap_pipeline_trust.json

  # Longer than the plan role because account creation is slow — AWS Organizations
  # provisioning takes minutes per account. Still bounded.
  max_session_duration = 7200

  # NO permissions boundary on this role, and that is a deliberate exception.
  #
  # A boundary here would have to permit organizations:*, account creation, SCP
  # management and IAM administration for bootstrap to work at all — at which point
  # it constrains almost nothing while implying it does. An honest absence beats a
  # boundary that looks like a control and is not.
  #
  # The boundary that matters is the one bootstrap CREATES in each member account,
  # which caps what project pipelines can do. That is where a ceiling has teeth.
}

# AdministratorAccess, attached rather than written.
#
# Managed rather than inline so it is obvious in the console and in any audit that
# this role is unrestricted, instead of being buried in a long inline document that
# reads as if it were scoped.
resource "aws_iam_role_policy_attachment" "bootstrap_pipeline_admin" {
  role       = aws_iam_role.bootstrap_pipeline.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
}

# --------------------------------------------------------------------------
# ACCOUNT REQUEST ROLE — writes one email parameter, and nothing else.
# --------------------------------------------------------------------------
#
# The request-account workflow needs to store an account's email before the account is
# created, so it never has to travel through git or a plan artifact.
#
# It gets its OWN role rather than reusing either of the others, and both alternatives
# are worse:
#
#   the plan role   is read-only and cannot write a parameter
#   the apply role  is AdministratorAccess behind an approval gate, so requesting an
#                   account would require the same approval as creating one, which
#                   defeats the point of a request step
#
# So: a third role, assumable from any branch like the plan role, permitted to write
# EXACTLY the email parameters and read nothing else. If this role leaks, the worst
# available action is setting an email on an account that does not exist yet.
#
# NOTE it can overwrite an existing parameter. That is a real limitation of a
# prefix-scoped policy — IAM cannot express "create but never update" for SSM. The
# protection against changing a live account's email is on the Terraform side:
# `ignore_changes = [email]`, so an overwritten parameter cannot move an existing
# account. The workflow also refuses to overwrite.
data "aws_iam_policy_document" "account_request_trust" {
  statement {
    sid     = "GitHubActionsRequestFromAnyBranch"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
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

resource "aws_iam_role" "account_request" {
  name        = "${var.org_prefix}-account-request-role"
  description = "GitHub Actions assumes this to store a requested account's email in SSM. Writes ${var.email_parameter_prefix}/* and nothing else."

  assume_role_policy   = data.aws_iam_policy_document.account_request_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "account_request" {
  statement {
    sid    = "WriteAccountEmailParametersOnly"
    effect = "Allow"

    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:AddTagsToResource",
    ]

    # Scoped to the email parameters. Not `parameter/*`, which would be every parameter
    # in the management account.
    resources = [
      "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${var.email_parameter_prefix}/*",
    ]
  }
}

resource "aws_iam_role_policy" "account_request" {
  name   = "write-account-emails"
  role   = aws_iam_role.account_request.id
  policy = data.aws_iam_policy_document.account_request.json
}
# Control Tower read permissions for the plan role.
#
# ReadOnlyAccess does not include newer Control Tower Baselines API actions.
# Once a CT baseline exists in state, Terraform refreshes it on every plan —
# which calls GetEnabledBaseline. Without this, the second account's plan fails
# with AccessDenied even though the first account's plan succeeded (no baseline
# in state yet to refresh).
data "aws_iam_policy_document" "bootstrap_plan_controltower" {
  statement {
    sid    = "ControlTowerRead"
    effect = "Allow"
    actions = [
      "controltower:Get*",
      "controltower:List*",
      "controltower:Describe*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "bootstrap_plan_controltower" {
  name   = "controltower-read"
  role   = aws_iam_role.bootstrap_plan.id
  policy = data.aws_iam_policy_document.bootstrap_plan_controltower.json
}