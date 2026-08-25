terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {}
}

# Default provider — assumes into EAF-DEV via the cross-account role AWS
# creates automatically in every member account.
provider "aws" {
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole"
    session_name = "eaf-workloads-dev"
  }
}

# Data sources resolved in the context of EAF-DEV.
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}
