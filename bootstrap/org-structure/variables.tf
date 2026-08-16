variable "org_prefix" {
  description = "Prefixes the resources this layer creates."
  type        = string
  default     = "eaf"
}

variable "management_account_id" {
  description = "The management account. This layer runs here and only here."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account id."
  }
}

variable "region" {
  description = "Region for this layer's own API calls. Organizations is global but the provider still needs one."
  type        = string
  default     = "eu-west-2"
}

variable "email_parameter_prefix" {
  description = <<-EOT
    SSM Parameter Store prefix holding one email per account, at
    `<prefix>/<ACCOUNT_NAME>/email`.

    WHY SSM RATHER THAN A VARIABLE OR THE REGISTER.

    An account's email becomes its root user and its only recovery address. It is
    personal data and it is permanent, so it stays out of git history and out of plan
    artifacts. The provider marks parameter values sensitive, so it does not appear in
    plan output either.

    It also has to be STABLE across runs. AWS Organizations has no API to change an
    account's email, so a value that differed between runs would make Terraform plan a
    change it cannot perform. Written once by the request-account workflow, read
    thereafter.
  EOT
  type        = string
  default     = "/eaf/accounts"

  validation {
    condition     = can(regex("^/[A-Za-z0-9._/-]+[^/]$", var.email_parameter_prefix))
    error_message = "email_parameter_prefix must start with / and not end with /."
  }
}

# NOTE: there is no `accounts` variable any more.
#
# It used to be a map passed in from the pipeline. Removed, because it made the pipeline
# a one-shot rather than reusable: a run that supplied only a NEW account would make
# Terraform plan to destroy every account not mentioned in that run.
#
# The account set now comes from `accounts/register.yaml`, a file that accumulates. See
# the reasoning at the top of accounts.tf.

# NOTE: there is no `state_bucket` variable either.
#
# It fed a `terraform_remote_state` read of the seed layer that nothing consumed —
# tflint caught it as declared-but-unused. The bucket this layer's state lives in comes
# from `backend.hcl`, which is a backend setting and was never the same thing as an
# input variable.

# NOTE: there is no `ou_name` variable any more.
#
# It hardcoded a single OU, which made this repository serve exactly one project. The OU
# each account lives in now comes from its `ou:` field in accounts/register.yaml, and any
# OU named there is created if it does not exist.
#
# `Workloads` was only ever a NAME, not a kind of object. Six other OUs already exist
# alongside it and are the same kind of thing.

variable "protected_ou_names" {
  description = <<-EOT
    OU names this repository must never manage. Checked against the register at plan time.

    This organization is not a sandbox. It holds 25 accounts including client and
    production work — aston-martin, Cupra.DRUK, positive-luxury, mlops-prod — governed by
    Control Tower. These six OUs belong to other teams.

    Naming one in the register would fail at create time anyway, because AWS rejects a
    duplicate OU name under the same parent. The guard exists so the failure says "that is
    not yours" at plan time rather than reading as a naming clash after a partial apply.

    Read from the live organization, not invented:

        aws organizations list-organizational-units-for-parent --parent-id <root>
  EOT
  type        = list(string)
  default     = ["Sandbox", "Security", "MLOps", "Apps", "Sprint BE", "Clients"]
}

variable "approved_regions" {
  description = <<-EOT
    The only regions accounts in this OU may use.

    eu-west-2 is London. The subject matter is UK statute, so keeping inference and data
    in the UK is a property of the product rather than a preference.

    us-east-1 is included NOT for workloads but because several AWS services are only
    addressable there even when the resources they manage are elsewhere: CloudFront,
    IAM, Route 53, and some billing APIs. Omitting it breaks those with errors that do
    not look like a region problem.
  EOT
  type        = list(string)
  default     = ["eu-west-2", "us-east-1"]
}

variable "enroll_in_control_tower" {
  description = <<-EOT
    Whether to register the new OU with AWS Control Tower.

    true is strongly preferred in this organization. Control Tower already governs the
    other six OUs, and enrolling means the new one inherits the same tested baseline —
    CloudTrail to the central Log Archive account, AWS Config recording, Identity Center
    access, and 16 preventive and detective controls.

    Leaving it false produces an OU that works but is governed by a second, weaker,
    hand-written model running in parallel with the org's real one. That divergence is
    the thing worth avoiding, not the missing features.
  EOT
  type        = bool
  default     = true
}

variable "control_tower_baseline_arn" {
  description = <<-EOT
    The AWSControlTowerBaseline ARN, read from this organization rather than guessed:

        aws controltower list-baselines

    Baseline ARNs are region-specific and account-agnostic.
  EOT
  type        = string
  default     = "arn:aws:controltower:eu-west-2::baseline/17BSJV3IGJ2QSGA2"
}

variable "control_tower_baseline_version" {
  description = <<-EOT
    Baseline version. **3.0**, matching every other OU in this organization.

    Verified with `aws controltower list-enabled-baselines`, not assumed — the first
    guess here was 4.0, which would have diverged from the rest of the org even if it
    had applied cleanly. Consistency with the existing OUs is the point.
  EOT
  type        = string
  default     = "3.0"
}

variable "identity_center_baseline_arn" {
  description = <<-EOT
    The ENABLED IdentityCenterBaseline in this organization, passed as a parameter to the
    OU baseline.

    Required, and easy to miss. AWSControlTowerBaseline depends on Identity Center
    already being enabled, and takes its enabled-baseline ARN as a parameter. Found by
    reading an existing OU's enrolment with `aws controltower get-enabled-baseline`, not
    from documentation.
  EOT
  type        = string
  default     = "arn:aws:controltower:eu-west-2:193027353132:enabledbaseline/XAFT1OVF9PI4SCQGR"
}
