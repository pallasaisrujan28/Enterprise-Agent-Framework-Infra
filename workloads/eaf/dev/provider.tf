terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.100.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.17.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.38.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.0"
    }
  }

  backend "s3" {}
}

# AWS provider — assumes into EAF-DEV via the cross-account role AWS creates
# automatically in every member account.
#
# RESTORED. Commit cff1ec9 removed this block, on the reasoning that
# eaf-workload-dev-deployer-role is already inside EAF-DEV so no hop is needed.
# True, and it cost two things:
#
#   1. That role is declared in THIS layer (iam.tf). A role cannot destroy the
#      layer that creates it — the destroy deletes its own authority partway
#      through and fails with an expired principal. Same for eaf-agent-ci-role,
#      which the application repository needs to push images.
#
#   2. It silently broke destroy-workloads.yml. That workflow declares
#      `environment: dev`, so its OIDC subject is `...:environment:dev`. The
#      deployer role's trust only accepts `...:ref:refs/heads/*`. Those do not
#      match, so it can no longer authenticate — where on 29 August, with this
#      block present and authenticating as eaf-baseline-dev-role, it destroyed
#      71 resources cleanly (run 33244371784).
#
# With the hop restored, the credential chain is:
#
#   GitHub OIDC
#     -> eaf-baseline-dev-role         (management 193027353132: state access,
#                                       and sts:AssumeRole on OrganizationAccountAccessRole
#                                       — it holds no resource permissions itself)
#     -> OrganizationAccountAccessRole (EAF-DEV 718438899462: does the work)
#
# Both survive any destroy of this layer, because neither is declared in it.
# That is the point.
provider "aws" {
  region = var.region

  assume_role {
    # Literal "aws" partition, NOT data.aws_partition.current.partition.
    #
    # A provider configuration is read as setup, before any work is planned, so
    # every value in it must be knowable without asking a provider anything. That
    # data source is served BY this provider, so referencing it here is circular —
    # the provider would need itself configured in order to configure itself.
    #
    # This is RC2 in miniature. accounts/dev/provider.tf uses the literal for the
    # same reason. If this repository ever runs outside the standard partition,
    # the partition becomes an input variable, never a data source.
    role_arn     = "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole"
    session_name = "eaf-workloads-dev"
  }
}

# Data sources resolved in the context of EAF-DEV.
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

# Helm provider — deploys into the EKS cluster.
#
# The --role-arn argument is RESTORED alongside the aws provider's assume_role.
# Without it, `aws eks get-token` mints a token for whoever the runner
# authenticated as — eaf-baseline-dev-role in the MANAGEMENT account — which has
# no EKS access entry on this cluster and would be refused by the API server.
# The token must be requested as the identity that actually holds cluster access.
#
# Note this block remains the RC2 fault: host and certificate come from
# aws_eks_cluster.this, a resource this same apply creates. The three-layer split
# fixes that by moving these providers into L2/L3 and sourcing them from
# data.aws_eks_cluster. Not fixed here — this layer is being deleted, and the fix
# belongs to the layer that replaces it.
provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", aws_eks_cluster.this.name,
        "--region", var.region,
        "--role-arn", "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole",
      ]
    }
  }
}

# Kubernetes provider — same reasoning as Helm above, including --role-arn.
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", aws_eks_cluster.this.name,
      "--region", var.region,
      "--role-arn", "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole",
    ]
  }
}
