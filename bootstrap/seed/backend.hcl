# Backend configuration for the SEED layer's own state.
#
#   PHASE 1 (new organization):  backend block in provider.tf is COMMENTED OUT.
#                                State is local. This file is unused.
#   PHASE 2 (immediately after): uncomment the block, then
#
#       terraform init -migrate-state -backend-config=backend.hcl
#
# Not secret. Account ids appear in every ARN. Committed so the pairing between
# an account and its state location is reviewable rather than remembered.

bucket = "eaf-bootstrap-tfstate-193027353132"
key    = "bootstrap/seed/terraform.tfstate"
region = "eu-west-2"

encrypt = true

# S3-native locking. Generally available since Terraform 1.11; the DynamoDB
# backend arguments are deprecated. No lock table exists, by design.
use_lockfile = true
