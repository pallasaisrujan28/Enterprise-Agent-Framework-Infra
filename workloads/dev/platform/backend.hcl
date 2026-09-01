# The key prefix is NOT a free choice.
#
# bootstrap/seed grants eaf-baseline-dev-role read/write on
# arn:aws:s3:::eaf-bootstrap-tfstate-.../workloads/dev/* and nothing else under
# workloads/. A key outside that prefix produces AccessDenied at `terraform init`,
# which reads as a credentials problem rather than a naming one.
#
# The same grant covers locking: s3:DeleteObject is permitted only on
# workloads/dev/*.tflock, so `use_lockfile` works here and would not one level up.
bucket       = "eaf-bootstrap-tfstate-193027353132"
key          = "workloads/dev/platform/terraform.tfstate"
region       = "eu-west-2"
use_lockfile = true
encrypt      = true
