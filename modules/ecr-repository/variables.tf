variable "name" {
  description = <<-EOT
    Repository name, e.g. `eaf/agent` or `tools/firecrawl`.

    A slash is a naming convention, not a hierarchy — ECR has no folders. `eaf/agent` is
    one repository whose name happens to contain a slash.
  EOT
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([._-]?[a-z0-9]+)*(/[a-z0-9]([._-]?[a-z0-9]+)*)*$", var.name))
    error_message = "name must be lowercase, and may contain letters, numbers, hyphens, underscores, periods and slashes."
  }
  validation {
    condition     = length(var.name) >= 2 && length(var.name) <= 256
    error_message = "name must be between 2 and 256 characters."
  }
}

variable "org_prefix" {
  description = "Short organisation prefix. Recorded as a tag, not prepended to the name — image references appear in manifests and are best kept short."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.org_prefix))
    error_message = "org_prefix must be lowercase, 2-12 characters, starting with a letter."
  }
}

variable "environment" {
  description = "dev | test | staging | prod"
  type        = string
  validation {
    condition     = contains(["dev", "test", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, staging, prod."
  }
}

variable "owner" {
  description = "Owning team, recorded as a mandatory tag."
  type        = string
  validation {
    condition     = length(var.owner) >= 3
    error_message = "owner must name a real team."
  }
}

# ── Tag mutability ────────────────────────────────────────────────────────────

variable "image_tag_mutability" {
  description = <<-EOT
    `IMMUTABLE`, `MUTABLE`, `IMMUTABLE_WITH_EXCLUSION` or `MUTABLE_WITH_EXCLUSION`.

    Defaults to IMMUTABLE. A tag, once pushed, can never point at a different image — so
    a deployed reference means exactly one thing forever, which is what makes a rollback
    reliable and an audit possible.

    THIS REPOSITORY HAS ALREADY BEEN BITTEN BY THE INTERACTION. An earlier `eaf/agent`
    was IMMUTABLE while its build workflow pushed both `:$${sha}` and `:latest` on every
    run. An immutable repository refuses to move an existing tag, so the FIRST push
    succeeded and every one after it failed. The tool repositories had the opposite
    problem: MUTABLE with `:latest`, so nobody could tell which image was deployed.

    The resolution is not a middle setting, it is to stop deploying `:latest`. Keep this
    IMMUTABLE and reference images by digest or commit SHA.

    `IMMUTABLE_WITH_EXCLUSION` exists for callers who genuinely need one moving tag; see
    `mutable_tag_exclusions`. Reaching for it to fix a failing push is treating the
    symptom.
  EOT
  type        = string
  default     = "IMMUTABLE"
  validation {
    condition = contains(
      ["IMMUTABLE", "MUTABLE", "IMMUTABLE_WITH_EXCLUSION", "MUTABLE_WITH_EXCLUSION"],
      var.image_tag_mutability
    )
    error_message = "image_tag_mutability must be one of: IMMUTABLE, MUTABLE, IMMUTABLE_WITH_EXCLUSION, MUTABLE_WITH_EXCLUSION."
  }
}

variable "mutable_tag_exclusions" {
  description = <<-EOT
    Tag prefixes exempted from the mutability rule, e.g. `["latest"]`.

    Only meaningful with `IMMUTABLE_WITH_EXCLUSION` or `MUTABLE_WITH_EXCLUSION`, and
    rejected otherwise rather than silently ignored.

    Every entry here is a tag that can be made to point somewhere else, so it is a tag
    nothing should be deployed from.
  EOT
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.mutable_tag_exclusions) <= 5
    error_message = "ECR permits at most 5 tag mutability exclusion filters."
  }
}

# ── Scanning ──────────────────────────────────────────────────────────────────

variable "scan_on_push" {
  description = <<-EOT
    Scan each image as it is pushed.

    On by default. A scan nobody asked for at push time is the only kind that reliably
    happens — a scheduled scan reports on images already running.

    This is BASIC scanning, which is per-repository and free. Enhanced scanning is a
    registry-wide setting backed by Amazon Inspector, configured once per account rather
    than per repository, and it is not this module's business.
  EOT
  type        = bool
  default     = true
}

# ── Encryption ────────────────────────────────────────────────────────────────

variable "kms_key_arn" {
  description = <<-EOT
    Customer-managed KMS key for encrypting images at rest.

    Null uses `AES256`, which is ECR's default and is still encryption at rest with an
    AWS-owned key. A CMK buys an auditable key policy and the ability to revoke access
    by disabling the key; it also costs per key per month and adds a policy to maintain.

    CANNOT BE CHANGED after the repository is created — switching means a new repository.
  EOT
  type        = string
  default     = null
  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:[a-z-]+:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a full KMS key ARN."
  }
}

# ── Lifecycle ─────────────────────────────────────────────────────────────────

variable "untagged_image_expiry_days" {
  description = <<-EOT
    Delete untagged images after this many days. Null disables the rule.

    Untagged images are what an immutable repository accumulates: push a new image for a
    tag that already exists in a *mutable* repo and the old one becomes untagged, and a
    multi-architecture build leaves intermediate manifests behind. Nothing references
    them and every one is billed.
  EOT
  type        = number
  default     = 7
  validation {
    condition     = var.untagged_image_expiry_days == null || var.untagged_image_expiry_days >= 1
    error_message = "untagged_image_expiry_days must be at least 1, or null to disable."
  }
}

variable "max_tagged_images" {
  description = <<-EOT
    Keep at most this many tagged images, deleting the oldest beyond it. Null disables.

    Worth setting on an immutable repository, because there is no other bound: every
    build adds a tag that is never replaced, so the repository grows forever.

    Keep enough to roll back to. 30 is several weeks of commits for a dev environment.
  EOT
  type        = number
  default     = 30
  validation {
    condition     = var.max_tagged_images == null || var.max_tagged_images >= 1
    error_message = "max_tagged_images must be at least 1, or null to disable."
  }
}

variable "expirable_tag_prefixes" {
  description = <<-EOT
    Restrict count-based expiry to tags with these prefixes, e.g. `["sha-", "dev-"]`.
    Anything not matching is then kept indefinitely.

    PHRASED AS AN ALLOWLIST BECAUSE ECR CANNOT EXPRESS THE OPPOSITE. A lifecycle rule
    SELECTS the images it acts on; there is no "except these" filter. So a variable
    called `protected_tag_prefixes` would have to be implemented by listing those
    prefixes in the rule's `tagPatternList` — which selects them FOR EXPIRY and deletes
    precisely the images it claims to protect. This module had that bug before it was
    ever applied.

    Empty means the count applies to every image in the repository, which is the simple
    and usually correct choice. Reach for this when a long-lived tag must survive: the
    count rule has no notion of importance, and a release tag is just an old one.
  EOT
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.expirable_tag_prefixes) <= 100
    error_message = "ECR permits at most 100 tag patterns in a lifecycle rule."
  }
}

# ── Deletion ──────────────────────────────────────────────────────────────────

variable "force_delete" {
  description = <<-EOT
    Allow the repository to be deleted while it still contains images.

    FALSE BY DEFAULT, and that default will make `terraform destroy` FAIL on any
    repository that has ever been pushed to. That is deliberate for anything holding
    images someone might need.

    It is also the wrong default for an environment that is torn down and rebuilt on
    purpose: there, a destroy that stops halfway leaves the rest of the layer standing
    and costing money. Set it true where images are disposable and rebuildable, and know
    that doing so means a destroy silently discards them.
  EOT
  type        = bool
  default     = false
}

# ── Access ────────────────────────────────────────────────────────────────────

variable "pull_principals" {
  description = <<-EOT
    IAM principal ARNs granted pull access through a repository policy, for cross-account
    pulls.

    Empty by default, and empty is correct for the common case: a principal in the SAME
    account pulls using its own IAM permissions, and adding it here would be redundant.
    A repository policy is for principals outside the account.
  EOT
  type        = list(string)
  default     = []
  validation {
    condition = alltrue([
      for p in var.pull_principals : can(regex("^arn:[a-z-]+:iam::[0-9]{12}:(role|user|root)", p))
    ])
    error_message = "each pull principal must be a full IAM role, user or account-root ARN."
  }
}

variable "extra_tags" {
  description = "Additional tags. Merged FIRST, so mandatory tags win on a key collision."
  type        = map(string)
  default     = {}
}
