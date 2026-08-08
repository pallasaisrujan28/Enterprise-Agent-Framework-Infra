# Backend for the ORGANIZATION layer's state.
#
#   terraform init -backend-config=backend.hcl
#
# Same bucket as the seed layer, DIFFERENT key. One state file per layer, so a
# change to the organization never carries seed's blast radius and vice versa.

bucket = "eaf-bootstrap-tfstate-193027353132"
key    = "bootstrap/organization/terraform.tfstate"
region = "eu-west-2"

encrypt      = true
use_lockfile = true
