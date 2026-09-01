# L1 — platform. VPC, EKS control plane, core add-ons, node group, and the IAM roles
# those need.
#
# ROOT module, so unlike the modules it composes this pins BOTH bounds. The modules
# constrain minimums only, leaving the choice of major to the layer that is actually
# deployed — this file is where that choice is made and the lock file records it.
terraform {
  required_version = "~> 1.13"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {}
}

# The pipeline authenticates as a role in the MANAGEMENT account and hops into EAF-DEV
# through the role AWS creates at account creation. That role trusts the management
# account, so no extra trust setup is needed.
#
# The hop is load-bearing and was removed once before. Without it, everything applies
# into the management account — and the failure is not obvious, because the apply
# succeeds.
#
# Note the literal "aws" partition rather than data.aws_partition.this.partition. A
# provider block cannot depend on a data source read by its own provider: the
# partition is unknown until the provider is configured, and configuring it needs the
# partition. RC2 in miniature. The partition is a fixed property of the deployment,
# so a literal is correct here even though it would not be inside a module.
provider "aws" {
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole"
    session_name = "eaf-workloads-dev-platform"
  }

  default_tags {
    tags = {
      Layer = "platform"
    }
  }
}
