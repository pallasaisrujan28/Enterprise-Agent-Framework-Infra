# GITHUB ACTIONS FEDERATION.
#
# No AWS keys stored in GitHub. GitHub signs a short-lived token describing the
# workflow run; AWS exchanges it for temporary credentials. Nothing to rotate,
# nothing to leak.
#
# The provider is ACCOUNT-LEVEL SHARED INFRASTRUCTURE, not project-owned. AWS
# permits one per URL per account, so "create our own alongside theirs" is not an
# option where one exists. Verified absent in the management account, so this
# creates it — but the toggle exists because that is not true of every account.

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  # The audience the aws-actions/configure-aws-credentials action requests.
  client_id_list = ["sts.amazonaws.com"]

  # No thumbprint_list. AWS validates GitHub's certificate against its own trusted
  # CA store for this provider, and the argument is optional in provider v6 —
  # confirmed by `terraform validate` accepting its absence. Pinning a thumbprint
  # would mean an outage when GitHub rotates its certificate.
}

locals {
  github_oidc_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # The `sub` claim GitHub puts in the token. Its shape depends on the trigger,
  # which is what makes ref-scoping possible at all:
  #
  #   repo:<owner>/<repo>:ref:refs/heads/main      push to main
  #   repo:<owner>/<repo>:pull_request             pull request event
  #   repo:<owner>/<repo>:environment:<name>       job declaring `environment:`
  #
  # This role uses the first form. The environment form is the stronger control
  # and is used by the per-account CI roles later: a token only carries an
  # environment claim if the job actually ran in that GitHub Environment, so where
  # that environment requires reviewers, the claim proves a human approved it.
  github_sub_main = "repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"
}
