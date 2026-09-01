# L0 — registry. Container repositories, and nothing else.
#
# WHY THIS IS ITS OWN LAYER, when the design originally put ECR in L1.
#
# The operating rhythm here is destroy-and-rebuild: the cluster is torn down whenever it is
# not being used, because it costs about $0.39 an hour to leave running. That makes the
# question "what should survive a teardown?" a design question rather than an afterthought.
#
# Images should survive. They are expensive to recreate — the agent image is built by a
# workflow in the APPLICATION repository, so a rebuild means remembering to trigger a
# second repository's pipeline and waiting for it — and almost free to keep, at roughly
# $0.10 per GB-month. A layer that is destroyed weekly is the wrong home for them.
#
# So this layer sits BELOW platform in lifetime, not in dependency: nothing here depends on
# the cluster, and the cluster does not depend on this. They are simply destroyed on
# different schedules, and Terraform has no way to express that other than a layer boundary.
terraform {
  required_version = "~> 1.13"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {}
}

# The same cross-account hop every workloads layer makes. The literal "aws" partition
# rather than data.aws_partition, because a provider cannot depend on a data source read
# through its own provider.
provider "aws" {
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole"
    session_name = "eaf-workloads-dev-registry"
  }

  default_tags {
    tags = {
      Layer = "registry"
    }
  }
}
