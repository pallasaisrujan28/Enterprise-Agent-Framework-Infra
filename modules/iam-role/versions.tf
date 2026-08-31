# Reusable module: constrain the MINIMUM only.
#
# HashiCorp's guidance is explicit that reusable modules should constrain only
# their minimum allowed versions of Terraform and providers, leaving the caller
# free to upgrade, while ROOT modules use `~>` to set both bounds. This module
# therefore uses `>=` and every root module that calls it pins with `~>`.
#
# Minimums, and why each is what it is:
#
#   terraform >= 1.9.0
#     `optional()` inside an object type constraint needs >= 1.3. Cross-variable
#     references in `validation` blocks need >= 1.9, and this module uses them to
#     reject a trust object whose payload does not match its declared `type`.
#
#   aws >= 6.0.0
#     `aws_iam_role_policies_exclusive` and
#     `aws_iam_role_policy_attachments_exclusive` are used to make out-of-band
#     policy attachment self-correcting. Requiring 6.x also stops this repository
#     spanning two provider majors, which it currently does: bootstrap/* is on
#     `~> 6.57` while accounts/* and modules/account-baseline are on `~> 5.0`.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}
