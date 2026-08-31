# Reusable module: minimums only.
#
#   terraform >= 1.9.0   consistency with the other modules in this repository.
#   aws       >= 6.0.0   `node_repair_config` on aws_eks_node_group.
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}
