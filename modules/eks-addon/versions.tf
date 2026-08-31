# Reusable module: minimums only.
#
#   terraform >= 1.9.0   cross-variable references in `validation` blocks, used to
#                        require service_account whenever pod_identity_role_arn is set.
#   aws       >= 6.0.0   `pod_identity_association` on aws_eks_addon.
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}
