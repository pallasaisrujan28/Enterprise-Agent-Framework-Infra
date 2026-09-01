# L2 — cluster-addons. Namespaces, their baseline, and the StorageClass workloads use.
#
# Everything here is a KUBERNETES object. The layer creates no AWS resources; it only
# reads the platform layer's outputs to find the cluster and to authenticate.
terraform {
  required_version = "~> 1.13"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  backend "s3" {}
}

# ── Where the cluster is ──────────────────────────────────────────────────────
#
# Read from the platform layer's state, never rediscovered. Two reasons.
#
# A data source looking the cluster up by name would work, and would also let this layer
# apply against a cluster the platform layer does not manage — which is how two layers end
# up disagreeing about what exists. Reading the state makes the dependency explicit and
# makes a missing platform layer an obvious error rather than an empty result.
#
# It also avoids RC2's shape: the Kubernetes provider is configured from values that
# ALREADY EXIST in another layer's state, not from a resource this layer creates. A
# provider cannot depend on something its own configuration produces.
data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket = "eaf-bootstrap-tfstate-193027353132"
    key    = "workloads/dev/platform/terraform.tfstate"
    region = "eu-west-2"
  }
}

locals {
  cluster_name     = data.terraform_remote_state.platform.outputs.cluster_name
  cluster_endpoint = data.terraform_remote_state.platform.outputs.cluster_endpoint
  cluster_ca       = data.terraform_remote_state.platform.outputs.cluster_certificate_authority_data
}

# The same cross-account hop the platform layer makes. Not used to create anything here —
# it exists so `aws eks get-token` below runs against the right account, and so the
# provider is configured consistently if this layer ever does need an AWS resource.
provider "aws" {
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole"
    session_name = "eaf-workloads-dev-cluster-addons"
  }
}

# ── Talking to the cluster ────────────────────────────────────────────────────
#
# THE --role-arn IS LOAD-BEARING, and omitting it fails in a confusing way.
#
# The pipeline authenticates as a role in the MANAGEMENT account. The cluster's access
# entry is for OrganizationAccountAccessRole in EAF-DEV. So a token minted as the
# management role is a valid AWS identity that the cluster has never heard of, and the
# result is a 401 from the Kubernetes API — which reads as a missing access entry rather
# than as the wrong identity.
#
# `aws eks get-token --role-arn` assumes the role first, so the token carries the identity
# the cluster actually knows. It mirrors the assume_role above; the two must agree.
#
# An `exec` credential plugin rather than data.aws_eks_cluster_auth: the token is fetched
# when the provider needs it rather than being read at plan time and expiring during a
# long apply.
provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", local.cluster_name,
      "--region", var.region,
      "--role-arn", "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole",
    ]
  }
}
