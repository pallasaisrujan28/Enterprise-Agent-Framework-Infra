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

variable "state_bucket" {
  description = "State bucket created by the seed layer. Passed in so this layer can read seed's outputs."
  type        = string
}

variable "region" {
  description = "Region for this layer's own API calls. Organizations is global but the provider still needs one."
  type        = string
  default     = "eu-west-2"
}

variable "ou_name" {
  description = <<-EOT
    The OU (folder) our accounts live in.

    An OU holds no resources and costs nothing. Its purpose is to be something
    rules attach to: every account inside inherits the OU's SCPs automatically, so
    adding an account later needs no extra policy work.
  EOT
  type        = string
  default     = "Workloads"
}

variable "approved_regions" {
  description = <<-EOT
    The only regions accounts in this OU may use.

    eu-west-2 is London. The subject matter is UK statute, so keeping inference and
    data in the UK is a property of the product rather than a preference.

    us-east-1 is included NOT for workloads but because several AWS services are
    only addressable there even when the resources they manage are elsewhere:
    CloudFront, IAM, Route 53, and some billing APIs. Omitting it breaks those with
    errors that do not look like a region problem.
  EOT
  type        = list(string)
  default     = ["eu-west-2", "us-east-1"]
}

variable "accounts" {
  description = <<-EOT
    The accounts to create in the OU, keyed by account name.

    A MAP with for_each, not a list with count. That is deliberate and it matters:
    with `count`, removing the first item shifts every later index, and Terraform
    reads that as "destroy and recreate everything after it". For AWS accounts that
    would be catastrophic. With `for_each`, keys are stable and removing one entry
    affects only that entry.

    Adding an account later is therefore one map entry, not a new directory.

    EMAILS ARE NOT DEFAULTED, AND MUST NOT BE.

    Each AWS account needs a globally unique email, and it becomes the root user
    and account-recovery address. Supplied at run time from the workflow input
    rather than committed here.

    THE TRAP, worth reading before changing anything: AWS Organizations has NO API
    to change an account's email. If a later run supplies a different value —
    including an empty one — Terraform plans a change it cannot perform, and fails
    mid-apply. And accounts cannot be cleanly deleted: closure takes 90 days and
    closed accounts still count against the org quota.

    So emails must be STABLE across runs. Create with a deliberate manual pipeline
    run, then store the values (SSM or a GitHub variable) so routine runs never
    re-prompt. `prevent_destroy` on the resource is the backstop.
  EOT

  type = map(object({
    email = string
    # Free-text label for tagging and for the account-baseline layer to key off.
    environment = string
  }))

  # No default. An empty default would let a routine apply plan the destruction of
  # accounts that already exist.
  validation {
    condition     = length(var.accounts) > 0
    error_message = "At least one account must be supplied. Emails come from the pipeline input, never from code."
  }

  validation {
    condition = alltrue([
      for k, v in var.accounts : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", v.email))
    ])
    error_message = "Every account needs a syntactically valid email. AWS requires it to be globally unique and it becomes the root user address."
  }

  validation {
    condition     = length(distinct([for k, v in var.accounts : lower(v.email)])) == length(var.accounts)
    error_message = "Account emails must be unique. AWS rejects a duplicate, and two accounts cannot share an address."
  }
}

variable "enroll_in_control_tower" {
  description = <<-EOT
    Whether to register the new OU with AWS Control Tower.

    true is strongly preferred in this organization. Control Tower already governs
    the other six OUs, and enrolling means the new one inherits the same tested
    baseline — CloudTrail to the central Log Archive account, AWS Config recording,
    Identity Center access, and 16 preventive and detective controls.

    Leaving it false produces an OU that works but is governed by a second, weaker,
    hand-written model running in parallel with the org's real one. That divergence
    is the thing worth avoiding, not the missing features.
  EOT
  type        = bool
  default     = true
}

variable "control_tower_baseline_arn" {
  description = <<-EOT
    The AWSControlTowerBaseline ARN, read from this organization rather than
    guessed:

        aws controltower list-baselines

    Baseline ARNs are region-specific and account-agnostic.
  EOT
  type        = string
  default     = "arn:aws:controltower:eu-west-2::baseline/17BSJV3IGJ2QSGA2"
}

variable "control_tower_baseline_version" {
  description = <<-EOT
    Baseline version. **3.0**, matching every other OU in this organization.

    Verified with `aws controltower list-enabled-baselines`, not assumed — the
    first guess here was 4.0, which would have diverged from the rest of the org
    even if it had applied cleanly. Consistency with the existing OUs is the point.
  EOT
  type        = string
  default     = "3.0"
}

variable "identity_center_baseline_arn" {
  description = <<-EOT
    The ENABLED IdentityCenterBaseline in this organization, passed as a parameter
    to the OU baseline.

    Required, and easy to miss. AWSControlTowerBaseline depends on Identity Center
    already being enabled, and takes its enabled-baseline ARN as a parameter. Found
    by reading an existing OU's enrolment with
    `aws controltower get-enabled-baseline`, not from documentation.
  EOT
  type        = string
  default     = "arn:aws:controltower:eu-west-2:193027353132:enabledbaseline/XAFT1OVF9PI4SCQGR"
}
