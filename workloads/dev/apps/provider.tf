# L3 — apps. The workloads themselves.
#
# Reads TWO layers below it, for different reasons:
#   platform       — where the cluster is, and how to authenticate to it
#   cluster-addons — the namespaces and the StorageClass its workloads deploy into
#
# The second is what makes the apply-order dependency explicit. Nothing in Terraform enforces
# that L2 ran before L3; reading its state means a missing L2 is an error naming the missing
# output rather than a namespace-not-found failure from the Kubernetes API halfway through.
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
    helm = {
      # ~> 3.0, NOT the 2.17.0 the design's version table still lists.
      #
      # That table predates the rebuild and is stale: cluster-addons already runs kubernetes
      # 3.2.1. Pinning helm to v2 here would mean two adjacent layers on different provider
      # generations, and v2 syntax is not forward compatible — `set`, `postrender` and the
      # provider's own `kubernetes` block all became typed ATTRIBUTES in v3.
      #
      # Writing v3 from the start avoids a migration whose whole content is syntax.
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {}
}

# ── Where the cluster is ──────────────────────────────────────────────────────

data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket = "eaf-bootstrap-tfstate-193027353132"
    key    = "workloads/dev/platform/terraform.tfstate"
    region = "eu-west-2"
  }
}

# ── What the cluster already provides ─────────────────────────────────────────
#
# Namespaces, the StorageClass, and — importantly — whether NetworkPolicy is actually
# enforced. That last one is read rather than restated: this layer's Neo4j module needs to
# know, and a second variable holding the same belief is a second place for it to be wrong.
data "terraform_remote_state" "cluster_addons" {
  backend = "s3"

  config = {
    bucket = "eaf-bootstrap-tfstate-193027353132"
    key    = "workloads/dev/cluster-addons/terraform.tfstate"
    region = "eu-west-2"
  }
}

# ── Where the images are ──────────────────────────────────────────────────────
#
# Read from the registry layer rather than assembled from account id and region. The ECR
# endpoint format is stable enough to hardcode, but reading it makes the dependency explicit:
# a Firecrawl deploy against a registry whose repositories do not exist should fail naming the
# missing output, not fail later on an image pull that reads as a permissions problem.
#
# It is also the layer that guarantees the repositories exist at all, which is Property 6's
# ordering requirement expressed as a data dependency.
data "terraform_remote_state" "registry" {
  backend = "s3"

  config = {
    bucket = "eaf-bootstrap-tfstate-193027353132"
    key    = "workloads/dev/registry/terraform.tfstate"
    region = "eu-west-2"
  }
}

locals {
  cluster_name     = data.terraform_remote_state.platform.outputs.cluster_name
  cluster_endpoint = data.terraform_remote_state.platform.outputs.cluster_endpoint
  cluster_ca       = data.terraform_remote_state.platform.outputs.cluster_certificate_authority_data

  storage_class_name = data.terraform_remote_state.cluster_addons.outputs.storage_class_name
  namespace_names    = data.terraform_remote_state.cluster_addons.outputs.namespace_names

  # `enforced` is the only value that means anything is actually enforcing policy. The
  # cluster-addons layer computes it from whether the vpc-cni add-on has network policy
  # turned on, so this is a fact about the cluster rather than an assumption.
  # Per namespace, not one value reused. The cluster-addons layer derives all of these from
  # the same cluster-wide vpc-cni setting today, so they agree — but reading the memory
  # namespace's state and applying it to a workload in `tools` would be correct by coincidence
  # rather than by construction, and would quietly stop being correct if enforcement ever
  # became per-namespace.
  policy_state = data.terraform_remote_state.cluster_addons.outputs.network_policy_state

  network_policy_state    = try(local.policy_state[var.memory_namespace], "unknown")
  network_policy_enforced = local.network_policy_state == "enforced"

  firecrawl_policy_state    = try(local.policy_state[var.firecrawl_namespace], "unknown")
  firecrawl_policy_enforced = local.firecrawl_policy_state == "enforced"

  # The registry host, derived from any one repository URL. A repository URL is
  # `<registry>/<name>`, so the host is everything before the first slash — taken from the
  # data rather than rebuilt from parts that could disagree with it.
  ecr_registry = split("/", values(data.terraform_remote_state.registry.outputs.repository_urls)[0])[0]

  # The credential-bearing exec args, written once. The kubernetes and helm providers must
  # authenticate identically; two copies of this list is two things to keep in step.
  eks_token_args = [
    "eks", "get-token",
    "--cluster-name", local.cluster_name,
    "--region", var.region,
    "--role-arn", "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole",
  ]
}

provider "aws" {
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole"
    session_name = "eaf-workloads-dev-apps"
  }
}

# ── Talking to the cluster ────────────────────────────────────────────────────
#
# THE --role-arn IS LOAD-BEARING. The pipeline authenticates as a role in the MANAGEMENT
# account, while the cluster's access entry is for OrganizationAccountAccessRole in EAF-DEV.
# A token minted as the management role is a valid AWS identity the cluster has never heard
# of, and the result is a 401 that reads as a missing access entry rather than a wrong one.
provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_token_args
  }
}

# THE SYNTAX HERE IS v3 AND IS NOT INTERCHANGEABLE WITH v2.
#
# In helm v2, `kubernetes` was a nested BLOCK and so was `exec` inside it. In v3 both are
# typed ATTRIBUTES, so this is `kubernetes = { ... exec = { ... } }` with equals signs and
# braces. Written as blocks it fails with an "unsupported block type" error that names the
# block but not the provider version that changed it.
provider "helm" {
  kubernetes = {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_token_args
    }
  }
}
