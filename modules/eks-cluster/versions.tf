# Reusable module: minimums only.
#
#   terraform >= 1.9.0   cross-variable references in `validation` blocks.
#   aws       >= 6.0.0   `access_config` and the access-entry resources. Also matches
#                        the rest of this repository — spanning provider majors
#                        across modules is how a shared module becomes unshareable.
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}
