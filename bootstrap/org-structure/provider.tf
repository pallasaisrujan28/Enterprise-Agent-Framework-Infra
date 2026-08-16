# LAYER 1 — ORGANIZATION. Runs in the MANAGEMENT account, applied by the pipeline.
#
# Creates the Workloads OU, the accounts inside it, and the SCPs attached to it.
#
# IMPORTANT CONTEXT ABOUT THIS ORGANIZATION, because it changes what is safe here:
#
# This is NOT an empty sandbox org. It has 25 accounts including client and
# production work (aston-martin, Cupra.DRUK, positive-luxury, mlops-prod), on a
# shared corporate domain. AWS Control Tower manages it, with a landing zone and
# ~30 of its own `aws-guardrails-*` SCPs.
#
# Therefore this layer is STRICTLY ADDITIVE:
#
#   - It creates a NEW OU. It does not touch Sandbox, Security, MLOps, Apps,
#     Sprint BE or Clients.
#   - It attaches SCPs only to the OU it created.
#   - It does not modify, detach or reorder any existing policy.
#   - It does not move any existing account.
#
# Anything that would alter another team's governance belongs in a conversation,
# not in this file.

terraform {
  required_version = ">= 1.13.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.57"
    }
  }

  # Partial config. Values in backend.hcl, which points at the bucket the seed
  # layer created. A DIFFERENT key from seed, so the two never share state.
  backend "s3" {}
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      Project   = var.org_prefix
      Layer     = "bootstrap-organization"
      ManagedBy = "terraform"
    }
  }
}

# NO `terraform_remote_state` READ OF THE SEED LAYER, and that is deliberate.
#
# An earlier version declared one, intending to pull seed's outputs. tflint caught it
# as declared-but-unused, which was correct: this layer needs exactly one thing from
# seed: the bucket its own state lives in, and that comes from `backend.hcl`.
#
# Removed rather than wired up. Reading another layer's state means this layer needs
# read access to it and fails if seed's state moves, in exchange for a value the
# pipeline already has. A narrow variable is the looser coupling.

data "aws_partition" "current" {}
data "aws_organizations_organization" "current" {}

locals {
  partition = data.aws_partition.current.partition

  # The organizational root — the top of the OU tree. NOT the management account,
  # despite both being called "root" in AWS's own docs. Read from the API rather
  # than hardcoded as "r-inc0", so this configuration is not tied to one org.
  org_root_id = data.aws_organizations_organization.current.roots[0].id
}

# NOTE: no `aws_caller_identity` and no `local.account_id` either. Also flagged
# unused by tflint. The account guard is already enforced by `allowed_account_ids` on
# the provider above, which fails before any API call rather than after.
