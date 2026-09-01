# Same constraint as every layer under workloads/: bootstrap/seed grants
# eaf-baseline-dev-role access to workloads/dev/* and nothing else, so the key must sit
# under that prefix. Anything outside it fails at `terraform init` with AccessDenied,
# which reads as a credentials problem rather than a naming one.
bucket       = "eaf-bootstrap-tfstate-193027353132"
key          = "workloads/dev/cluster-addons/terraform.tfstate"
region       = "eu-west-2"
use_lockfile = true
encrypt      = true
