# LAYER 0 — SEED. Run ONCE, from a laptop, by a human with admin in the
# MANAGEMENT account. Everything else in this repository depends on it.
#
# It exists to break two circular dependencies:
#
#   1. Terraform state belongs in S3, but the bucket must exist before the
#      configuration that uses it can run.
#   2. The pipeline should authenticate by federation to a role, but neither the
#      identity provider nor the role can be created by the pipeline that needs
#      them in order to authenticate at all.
#
# Nothing else belongs here. Seed is not a home for anything awkward.

terraform {
  required_version = ">= 1.13.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned to the minor. `~> 6.57` accepts 6.57.x patches and refuses 6.58,
      # so a provider release cannot silently change a plan.
      version = "~> 6.57"
    }
  }

  # TWO-PHASE. This is phase 2.
  #
  # Phase 1 — first apply in a new organization, with this block COMMENTED OUT.
  #   State is local, because the bucket it would live in is what this apply
  #   creates. The only moment local state is correct.
  #
  # Phase 2 — uncomment, then:
  #
  #       terraform init -migrate-state -backend-config=backend.hcl
  #
  #   Terraform copies the local state into the bucket phase 1 created and
  #   switches over. Confirm with `terraform plan` reporting no changes, then
  #   delete the local state file and confirm no changes AGAIN with nothing on
  #   disk. State is never committed.
  #
  # Partial configuration: the bucket name contains the account id, so it cannot
  # be written here without hardcoding an account. Values live in backend.hcl.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  # Refuse to run against an account this configuration was not written for.
  #
  # Not paranoia. A developer machine carries credentials for several accounts and
  # the active one is chosen by ambient environment, not by anything in this
  # repository. This exact trap has already been hit here: an empty credential
  # variable caused the CLI to fall through to another account's credentials and
  # answer successfully, appearing to describe the management account while
  # describing a member account.
  #
  # The management account is the worst place for that to happen silently — SCPs
  # do not apply to it and it can reach every other account.
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      Project   = var.org_prefix
      Layer     = "bootstrap-seed"
      ManagedBy = "terraform"
      Repo      = var.github_repository
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}
