# Reusable module: minimums only.
#
# HashiCorp's guidance is that reusable modules constrain only their minimum
# allowed versions, leaving the caller free to upgrade, while root modules use `~>`
# to set both bounds.
#
#   terraform >= 1.9.0   cross-variable references in `validation` blocks, used to
#                        reject a subnet plan that cannot fit in the VPC CIDR.
#   aws       >= 6.0.0   matches the rest of this repository. Nothing here needs
#                        6.x specifically, but spanning provider majors across
#                        modules is how a shared module becomes unshareable.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}
