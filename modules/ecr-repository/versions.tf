# Reusable module: minimums only.
#
#   aws >= 6.0.0   `image_tag_mutability_exclusion_filter`, and the
#                  IMMUTABLE_WITH_EXCLUSION / MUTABLE_WITH_EXCLUSION modes.
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}
