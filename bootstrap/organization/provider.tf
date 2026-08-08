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

# Read the seed layer's outputs rather than hardcoding them. A copied ARN drifts
# silently the moment seed changes, and the failure appears as a permission error
# with no obvious cause.
data "terraform_remote_state" "seed" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "bootstrap/seed/terraform.tfstate"
    region = var.region
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_organizations_organization" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # The organizational root — the top of the OU tree. NOT the management account,
  # despite both being called "root" in AWS's own docs. Read from the API rather
  # than hardcoded as "r-inc0", so this configuration is not tied to one org.
  org_root_id = data.aws_organizations_organization.current.roots[0].id
}
