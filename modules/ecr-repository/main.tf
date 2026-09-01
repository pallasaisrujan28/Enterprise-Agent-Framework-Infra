# One ECR repository, with a lifecycle policy, scan-on-push and immutable tags.
#
# Kubernetes pulls images from here. If an image is not present, a pod stays in
# ImagePullBackOff — which reads as a broken deployment rather than an empty registry.

locals {
  mandatory_tags = {
    ManagedBy       = "terraform"
    ManagedByModule = "modules/ecr-repository"
    OrgPrefix       = var.org_prefix
    Environment     = var.environment
    Owner           = var.owner
  }

  tags = merge(var.extra_tags, local.mandatory_tags)

  uses_exclusions = endswith(var.image_tag_mutability, "_WITH_EXCLUSION")

  # ── Lifecycle policy ────────────────────────────────────────────────────────
  #
  # Built as data rather than a heredoc so the rule priorities cannot collide and the
  # rules cannot be reordered by accident. ECR evaluates by ascending priority and
  # requires each to be unique.
  #
  # Order matters for a reason beyond tidiness: the untagged rule runs FIRST, so images
  # already unreferenced are removed before the count-based rule considers tagged ones.
  # Reversed, the count rule could delete a tagged image while untagged ones survived.

  untagged_rule = var.untagged_image_expiry_days == null ? [] : [{
    rulePriority = 1
    description  = "Expire untagged images after ${var.untagged_image_expiry_days} days"
    selection = {
      tagStatus   = "untagged"
      countType   = "sinceImagePushed"
      countUnit   = "days"
      countNumber = var.untagged_image_expiry_days
    }
    action = { type = "expire" }
  }]

  # A lifecycle rule SELECTS what it acts on. There is no exclusion filter, so
  # expirable_tag_prefixes is an ALLOWLIST of what may be expired — anything not listed
  # survives. Inverting that reading is how the first version of this module would have
  # deleted exactly the release tags it was meant to keep.
  #
  # Two separate locals rather than one with a conditional `selection`, because the two
  # shapes differ — one carries tagPatternList and the other does not — and Terraform
  # refuses to unify the branches of a conditional into a single object type. concat
  # produces a tuple, which tolerates the difference.
  #
  # `any` rather than `tagged` in the unfiltered case: ECR requires a tag filter alongside
  # tagStatus = "tagged", and an empty filter is rejected rather than read as "everything".

  count_rule_all = var.max_tagged_images == null || length(var.expirable_tag_prefixes) > 0 ? [] : [{
    rulePriority = 2
    description  = "Keep the ${var.max_tagged_images} most recent images"
    selection = {
      tagStatus   = "any"
      countType   = "imageCountMoreThan"
      countNumber = var.max_tagged_images
    }
    action = { type = "expire" }
  }]

  count_rule_filtered = var.max_tagged_images == null || length(var.expirable_tag_prefixes) == 0 ? [] : [{
    rulePriority = 2
    description  = "Keep the ${var.max_tagged_images} most recent images tagged ${join(", ", var.expirable_tag_prefixes)}; others are never expired"
    selection = {
      tagStatus      = "tagged"
      tagPatternList = [for p in var.expirable_tag_prefixes : "${p}*"]
      countType      = "imageCountMoreThan"
      countNumber    = var.max_tagged_images
    }
    action = { type = "expire" }
  }]

  lifecycle_rules = concat(local.untagged_rule, local.count_rule_all, local.count_rule_filtered)
}

resource "aws_ecr_repository" "this" {
  name = var.name

  image_tag_mutability = var.image_tag_mutability

  # Only valid with a *_WITH_EXCLUSION mutability. Sending it otherwise is rejected by
  # the API, so the precondition below catches it at plan time instead.
  dynamic "image_tag_mutability_exclusion_filter" {
    for_each = local.uses_exclusions ? var.mutable_tag_exclusions : []
    content {
      filter      = image_tag_mutability_exclusion_filter.value
      filter_type = "WILDCARD"
    }
  }

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = var.kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.kms_key_arn
  }

  # False refuses to delete a repository that still holds images, which makes
  # `terraform destroy` fail rather than silently discard them.
  force_delete = var.force_delete

  tags = merge(local.tags, { Name = var.name })

  lifecycle {
    precondition {
      condition = local.uses_exclusions || length(var.mutable_tag_exclusions) == 0
      error_message = join(" ", [
        "mutable_tag_exclusions is set but image_tag_mutability is ${var.image_tag_mutability}.",
        "Exclusion filters are only valid with IMMUTABLE_WITH_EXCLUSION or",
        "MUTABLE_WITH_EXCLUSION. Sending them otherwise is rejected by the API, and",
        "leaving them here would read as protection that is not in effect.",
      ])
    }

    precondition {
      condition     = !local.uses_exclusions || length(var.mutable_tag_exclusions) > 0
      error_message = "image_tag_mutability is ${var.image_tag_mutability} but no mutable_tag_exclusions were given, which is the same as plain ${replace(var.image_tag_mutability, "_WITH_EXCLUSION", "")} and misleading. Set the filters or use the plain mode."
    }
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  count = length(local.lifecycle_rules) > 0 ? 1 : 0

  repository = aws_ecr_repository.this.name
  policy     = jsonencode({ rules = local.lifecycle_rules })
}

# ── Cross-account pull ────────────────────────────────────────────────────────
#
# Only created when principals are named. A principal in the same account pulls using its
# own IAM permissions; a repository policy is for principals outside it.

resource "aws_ecr_repository_policy" "this" {
  count = length(var.pull_principals) > 0 ? 1 : 0

  repository = aws_ecr_repository.this.name

  # jsonencode rather than aws_iam_policy_document, matching modules/iam-role.
  #
  # The data source is computed BY the provider, so under a mocked provider its `json` is
  # a stub and no test can assert on what the policy actually says. For a policy whose
  # whole point is which actions it does NOT grant, that is the difference between a test
  # and a decoration.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowPull"
      Effect    = "Allow"
      Principal = { AWS = var.pull_principals }

      # Pull only, and deliberately three actions rather than four.
      #
      # ecr:GetAuthorizationToken is ABSENT because a repository policy cannot grant it —
      # it is an account-level action against the registry, not against a repository.
      # Listing it here would apply cleanly and look like it did something; the pulling
      # principal has to hold it in its own IAM policy.
      Action = [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability",
      ]
    }]
  })
}
