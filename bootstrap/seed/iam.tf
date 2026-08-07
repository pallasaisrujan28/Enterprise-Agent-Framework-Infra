# THE BOOTSTRAP PIPELINE ROLE.
#
# This role is the most privileged thing this repository creates:
# AdministratorAccess in the MANAGEMENT account. It has to be — it creates
# accounts, OUs and SCPs, and there is no narrower AWS-managed policy that covers
# Organizations administration.
#
# Because the permissions cannot meaningfully be reduced, THE TRUST POLICY IS THE
# CONTROL. Everything defensible about this role is in who may assume it:
#
#   - one identity provider
#   - one audience
#   - one repository
#   - one branch
#
# A pull request from any branch cannot reach it. Another repository in the same
# organization cannot reach it. That is the whole security model, so the
# conditions below are not boilerplate.

data "aws_iam_policy_document" "bootstrap_pipeline_trust" {
  statement {
    sid     = "GitHubActionsMainBranchOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    # Without the audience condition, a token minted for a different audience
    # could be replayed here.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals, not StringLike, and no wildcard anywhere in the value.
    #
    # `StringLike` with `repo:owner/repo:*` would also match `:pull_request`,
    # handing administrator access to code from an unreviewed branch. Pinning the
    # exact ref string is the difference between "our repository" and "our
    # repository's protected branch".
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_sub_main]
    }
  }
}

resource "aws_iam_role" "bootstrap_pipeline" {
  name        = "${var.org_prefix}-bootstrap-pipeline-role"
  description = "GitHub Actions assumes this to run bootstrap. Admin in the management account; trust is locked to ${var.github_repository}@${var.github_branch}."

  assume_role_policy = data.aws_iam_policy_document.bootstrap_pipeline_trust.json

  # Longer than the other roles because a full bootstrap apply creates accounts,
  # and account creation is slow — AWS Organizations account provisioning can take
  # several minutes per account. Still bounded.
  max_session_duration = 7200

  # NO permissions boundary on this role, and that is a deliberate exception.
  #
  # A boundary here would have to permit organizations:*, account creation, SCP
  # management and IAM administration in order for bootstrap to work — at which
  # point it constrains almost nothing while implying it does. An honest absence is
  # better than a boundary that looks like a control and is not.
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
