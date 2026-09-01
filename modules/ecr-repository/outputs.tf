output "name" {
  description = "Repository name."
  value       = aws_ecr_repository.this.name
}

output "arn" {
  description = "Repository ARN. Use this in an IAM policy that grants pull or push on this repository specifically."
  value       = aws_ecr_repository.this.arn
}

output "repository_url" {
  description = <<-EOT
    Full URL to reference images by, e.g.
    `718438899462.dkr.ecr.eu-west-2.amazonaws.com/eaf/agent`.

    Pass this to whatever builds the image and to whatever deploys it, rather than
    reconstructing it from an account id and region. A reconstructed string creates no
    dependency edge, so a change here breaks the consumer silently at apply.
  EOT
  value       = aws_ecr_repository.this.repository_url
}

output "registry_id" {
  description = "The account id hosting the registry. Needed by `aws ecr get-login-password` for a cross-account pull."
  value       = aws_ecr_repository.this.registry_id
}

output "inventory" {
  description = "Structured record of this repository, for cross-layer inventory and review."
  value = {
    name           = aws_ecr_repository.this.name
    arn            = aws_ecr_repository.this.arn
    repository_url = aws_ecr_repository.this.repository_url

    image_tag_mutability = var.image_tag_mutability
    mutable_tags         = endswith(var.image_tag_mutability, "_WITH_EXCLUSION") ? var.mutable_tag_exclusions : []

    # The single most consequential property, stated as a boolean rather than left to be
    # inferred from a mode name. False means a deployed tag can be repointed at a
    # different image, so a rollback is not reliable and an audit cannot be trusted.
    tags_are_immutable = var.image_tag_mutability == "IMMUTABLE"

    scan_on_push       = var.scan_on_push
    encryption         = var.kms_key_arn == null ? "AES256 (AWS-owned key)" : "KMS: ${var.kms_key_arn}"
    encrypted_with_cmk = var.kms_key_arn != null

    lifecycle = {
      untagged_expire_after_days = var.untagged_image_expiry_days
      max_tagged_images          = var.max_tagged_images
      expirable_tag_prefixes     = var.expirable_tag_prefixes

      # True when nothing bounds growth. Reported because the consequence is a bill that
      # rises quietly rather than an error.
      unbounded = var.untagged_image_expiry_days == null && var.max_tagged_images == null
    }

    # Reported because it decides whether `terraform destroy` can complete. False on a
    # repository holding images means the destroy fails partway, leaving the rest of the
    # layer standing and billing.
    destroyable_with_images = var.force_delete

    cross_account_pull_principals = var.pull_principals
  }
}
