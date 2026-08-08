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
  # "The provider's ARN, however we got it." Everything downstream uses this one
  # name and does not care which branch of the toggle produced it.
  #
  # The `[0]` is required because `count` turns a single thing into a list, even a
  # list of one. The two counts above are opposites, so exactly one side exists at a
  # time, and the conditional never evaluates the side that does not.
  github_oidc_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# NOTE: the `sub` claim strings used to live here and have MOVED to iam.tf.
#
# They were misleading in this file. This file creates the OIDC provider, and the
# provider knows nothing about repositories, branches or environments — it stores
# only an issuer URL and an allowed audience. Repository and branch scoping is a
# property of each ROLE's trust policy, so the strings belong next to the roles.
#
# Nothing changed behaviourally by moving them. Terraform reads every .tf file in a
# directory as one flat namespace, so a `locals` block behaves identically wherever
# it sits. The move is for whoever reads this next.
