# The key prefix is a constraint, not a preference. `bootstrap/seed/iam.tf` grants dev
# principals state access to `workloads/dev/*` only, and locks `workloads/dev/*.tflock`. A key
# outside that prefix fails at the layer's first `init` with AccessDenied against state.
bucket       = "eaf-bootstrap-tfstate-193027353132"
key          = "workloads/dev/apps/terraform.tfstate"
region       = "eu-west-2"
use_lockfile = true
encrypt      = true
