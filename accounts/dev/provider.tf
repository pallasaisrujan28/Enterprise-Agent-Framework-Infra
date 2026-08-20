terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}

# The provider assumes into EAF-DEV via the role AWS creates automatically
# at account creation. This role trusts the management account, so the
# pipeline credentials (which are already in the management account) can
# assume it without any additional setup.
provider "aws" {
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole"
    session_name = "eaf-accounts-dev-baseline"
  }
}
