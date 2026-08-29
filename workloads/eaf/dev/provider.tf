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
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {}
}

# AWS provider — no assume_role.
# GitHub Actions assumes eaf-workload-dev-deployer-role (OIDC directly in
# EAF-DEV). The shell is already operating inside EAF-DEV — no management
# account hop needed. The management account is not involved in workload
# operations.
provider "aws" {
  region = var.region
}

# Data sources resolved in the context of EAF-DEV.
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

# Helm provider — no --role-arn flag.
# The shell already holds eaf-workload-dev-deployer-role credentials.
# That role has an EKS access entry (AmazonEKSClusterAdminPolicy) so
# aws eks get-token succeeds with the current credentials as-is.
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
      ]
    }
  }
}

# Kubernetes provider — same pattern as Helm above.
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
    ]
  }
}
