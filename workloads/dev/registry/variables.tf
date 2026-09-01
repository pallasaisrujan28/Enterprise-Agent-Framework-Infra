variable "account_id" {
  description = "EAF-DEV account ID."
  type        = string
  default     = "718438899462"
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  description = "AWS region for the registry."
  type        = string
  default     = "eu-west-2"
}

variable "org_prefix" {
  description = "Short organisation prefix, recorded as a tag."
  type        = string
  default     = "eaf"
}

variable "environment" {
  description = "Environment name, recorded as a tag."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owning team, recorded as a mandatory tag."
  type        = string
  default     = "platform-team"
}

variable "repositories" {
  description = <<-EOT
    Repositories to create. One per image that gets deployed.

    A slash is a naming convention, not a hierarchy — `eaf/agent` is a single repository
    whose name contains a slash.

    `eaf/agent` is built by the APPLICATION repository's workflow, not this one. The
    repository is created here because the registry is infrastructure and the image is not:
    it must exist before anything can push, and a push to a missing repository fails with a
    message about authorisation rather than about absence.
  EOT
  type        = list(string)
  default = [
    "eaf/agent",
    "tools/firecrawl",
    "tools/firecrawl-playwright",
  ]
  validation {
    condition     = length(var.repositories) == length(toset(var.repositories))
    error_message = "repositories must not contain duplicates."
  }
}

variable "untagged_image_expiry_days" {
  description = "Delete untagged images after this many days."
  type        = number
  default     = 7
}

variable "max_tagged_images" {
  description = <<-EOT
    Keep at most this many tagged images per repository.

    Needed because tags here are immutable, so every build adds one that is never replaced
    and nothing else bounds growth. 30 is several weeks of commits, and enough to roll back
    to anything anyone remembers.
  EOT
  type        = number
  default     = 30
}

variable "force_delete" {
  description = <<-EOT
    Allow a repository to be deleted while it still holds images.

    FALSE HERE, deliberately, and the opposite of what the platform layer used.

    The whole reason this layer exists is that its contents should survive a teardown. A
    destroy that refuses to proceed while images are present is not an obstacle, it is the
    guard working: destroying this layer discards the images the rhythm is designed to keep.

    Setting it true means a `terraform destroy` on this layer silently throws away every
    image, including ones only the application repository's pipeline can rebuild.
  EOT
  type        = bool
  default     = false
}
