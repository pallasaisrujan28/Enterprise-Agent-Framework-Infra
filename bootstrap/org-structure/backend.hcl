# Backend for the ORG-STRUCTURE layer's state.
#
# Renamed from bootstrap/organization. Free to change because this layer had never been
# applied, so there was no state object to migrate - confirmed with
# `aws s3 ls s3://<bucket>/bootstrap/ --recursive`, which showed only seed's state.
#
#   terraform init -backend-config=backend.hcl
#
# Same bucket as the seed layer, DIFFERENT key. One state file per layer, so a
# change to the organization never carries seed's blast radius and vice versa.

bucket = "eaf-bootstrap-tfstate-193027353132"
key    = "bootstrap/org-structure/terraform.tfstate"
region = "eu-west-2"

encrypt      = true
use_lockfile = true
