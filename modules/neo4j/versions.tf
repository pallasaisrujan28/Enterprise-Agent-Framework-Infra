# Reusable module: minimums only. The choice of major belongs to the root module.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.0"
    }
    helm = {
      # >= 3.0.0 because modules/helm-release, which this module calls, is written against
      # the v3 schema. See its versions.tf.
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0.0"
    }
  }
}
