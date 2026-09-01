# Reusable module: minimums only.
#
#   kubernetes >= 2.0.0   `storage_class_v1`. Not pinned to 3.x: a StorageClass is a
#                         stable API and nothing here needs a 3.x feature, so the
#                         choice of major belongs to the root module.
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.0"
    }
  }
}
