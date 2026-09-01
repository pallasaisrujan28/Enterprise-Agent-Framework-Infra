# Under workloads/dev/ because that is the only prefix eaf-baseline-dev-role can write —
# bootstrap/seed grants it read/write on workloads/dev/* and nothing else. The path says
# nothing about lifetime; this layer is deliberately NOT destroyed with the others.
bucket       = "eaf-bootstrap-tfstate-193027353132"
key          = "workloads/dev/registry/terraform.tfstate"
region       = "eu-west-2"
use_lockfile = true
encrypt      = true
