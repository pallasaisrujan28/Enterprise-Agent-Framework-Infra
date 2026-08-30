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

# AWS provider — no assume_role needed.
# The pipeline authenticates as eaf-workload-dev-deployer-role which is already
# in EAF-DEV (718438899462). No cross-account hop required.
provider "aws" {
  region = var.region
}

# Data sources resolved in the context of EAF-DEV.
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

# Helm provider — uses deployer role credentials directly.
# eaf-workload-dev-deployer-role has an EKS access entry with ClusterAdmin.
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

# Kubernetes provider — same as Helm above.
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
