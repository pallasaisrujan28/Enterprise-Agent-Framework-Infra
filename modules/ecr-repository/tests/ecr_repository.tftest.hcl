# Unit tests for modules/ecr-repository.
#
# command = plan, mocked provider, no credentials.
# Verified to pass with every AWS environment variable unset.

mock_provider "aws" {}

variables {
  name        = "eaf/agent"
  org_prefix  = "eaf"
  environment = "dev"
  owner       = "platform-team"
}

run "defaults_are_immutable_and_scanned" {
  command = plan

  # The default that matters. A tag that can be repointed makes a rollback unreliable and
  # an audit meaningless.
  assert {
    condition     = aws_ecr_repository.this.image_tag_mutability == "IMMUTABLE"
    error_message = "tags must be immutable by default."
  }

  assert {
    condition     = one(aws_ecr_repository.this.image_scanning_configuration).scan_on_push == true
    error_message = "scan_on_push should default to true; a scan at push time is the only kind that reliably happens."
  }

  # AES256 is still encryption at rest, with an AWS-owned key.
  assert {
    condition     = one(aws_ecr_repository.this.encryption_configuration).encryption_type == "AES256"
    error_message = "encryption should default to AES256 rather than being absent."
  }

  # False refuses to delete a repository holding images, so a destroy fails rather than
  # silently discarding them. Safe default; wrong for a disposable environment.
  assert {
    condition     = aws_ecr_repository.this.force_delete == false
    error_message = "force_delete should default to false."
  }

  # No exclusion filters on plain IMMUTABLE.
  assert {
    condition     = length(aws_ecr_repository.this.image_tag_mutability_exclusion_filter) == 0
    error_message = "no exclusion filters should be emitted for plain IMMUTABLE."
  }
}

# ── The lifecycle bug this module had before it was ever applied ──────────────

run "count_rule_covers_everything_when_no_prefixes_given" {
  command = plan

  # tagStatus "any", not "tagged": ECR requires a tag filter alongside "tagged", and an
  # empty filter is rejected rather than read as "everything".
  assert {
    condition = (
      one([
        for r in jsondecode(one(aws_ecr_lifecycle_policy.this).policy).rules :
        r if r.rulePriority == 2
      ]).selection.tagStatus == "any"
    )
    error_message = "with no expirable prefixes the count rule must select tagStatus \"any\"."
  }

  # And no pattern list, because there is nothing to restrict it to.
  assert {
    condition = !can(
      one([
        for r in jsondecode(one(aws_ecr_lifecycle_policy.this).policy).rules :
        r if r.rulePriority == 2
      ]).selection.tagPatternList
    )
    error_message = "no tagPatternList should be sent when the rule applies to everything."
  }
}

run "expirable_prefixes_are_an_allowlist_not_a_denylist" {
  command = plan

  variables {
    expirable_tag_prefixes = ["sha-", "dev-"]
  }

  # THE REGRESSION. An ECR lifecycle rule SELECTS the images it acts on — there is no
  # exclusion filter. An earlier version of this module took `protected_tag_prefixes` and
  # put them in tagPatternList, which selects them FOR EXPIRY: it would have deleted
  # exactly the release tags it claimed to protect.
  #
  # This asserts the patterns are the ones we are WILLING TO DELETE.
  assert {
    condition = (
      join(",", one([
        for r in jsondecode(one(aws_ecr_lifecycle_policy.this).policy).rules :
        r if r.rulePriority == 2
      ]).selection.tagPatternList) == "sha-*,dev-*"
    )
    error_message = "tagPatternList must contain the EXPIRABLE prefixes — ECR selects what it deletes, it cannot exclude."
  }

  assert {
    condition = (
      one([
        for r in jsondecode(one(aws_ecr_lifecycle_policy.this).policy).rules :
        r if r.rulePriority == 2
      ]).selection.tagStatus == "tagged"
    )
    error_message = "a pattern list requires tagStatus \"tagged\"."
  }

  # And the description must say which way round it is, since the JSON alone is
  # ambiguous to a reader.
  assert {
    condition = strcontains(
      one([
        for r in jsondecode(one(aws_ecr_lifecycle_policy.this).policy).rules :
        r if r.rulePriority == 2
      ]).description,
      "others are never expired"
    )
    error_message = "the rule description should state that unlisted tags survive."
  }
}

run "untagged_rule_runs_before_the_count_rule" {
  command = plan

  # ECR evaluates by ascending priority. Untagged must go first: reversed, the count rule
  # could delete a tagged image while unreferenced ones survived.
  assert {
    condition = (
      one([for r in jsondecode(one(aws_ecr_lifecycle_policy.this).policy).rules : r if r.selection.tagStatus == "untagged"]).rulePriority == 1
    )
    error_message = "the untagged rule must have priority 1 so it runs first."
  }

  assert {
    condition     = length(jsondecode(one(aws_ecr_lifecycle_policy.this).policy).rules) == 2
    error_message = "expected both lifecycle rules by default."
  }
}

run "no_lifecycle_policy_when_both_rules_are_disabled" {
  command = plan

  variables {
    untagged_image_expiry_days = null
    max_tagged_images          = null
  }

  assert {
    condition     = length(aws_ecr_lifecycle_policy.this) == 0
    error_message = "no lifecycle policy resource should exist when no rules are configured."
  }

  # Unbounded growth is a bill that rises quietly rather than an error, so it is reported.
  assert {
    condition     = output.inventory.lifecycle.unbounded == true
    error_message = "the inventory must flag a repository with no growth bound."
  }
}

# ── Tag mutability exclusions ────────────────────────────────────────────────

run "exclusion_filters_are_emitted_for_the_exclusion_mode" {
  command = plan

  variables {
    image_tag_mutability   = "IMMUTABLE_WITH_EXCLUSION"
    mutable_tag_exclusions = ["latest"]
  }

  assert {
    condition = (
      one(aws_ecr_repository.this.image_tag_mutability_exclusion_filter).filter == "latest" &&
      one(aws_ecr_repository.this.image_tag_mutability_exclusion_filter).filter_type == "WILDCARD"
    )
    error_message = "the exclusion filter should be passed through with filter_type WILDCARD."
  }

  # tags_are_immutable is true only for plain IMMUTABLE. A mode that exempts some tags is
  # not the same thing, and the inventory must not blur them.
  assert {
    condition     = output.inventory.tags_are_immutable == false
    error_message = "IMMUTABLE_WITH_EXCLUSION must not report as fully immutable."
  }

  assert {
    condition     = join(",", output.inventory.mutable_tags) == "latest"
    error_message = "the inventory should name which tags can move."
  }
}

run "reject_exclusions_without_the_exclusion_mode" {
  command = plan

  variables {
    image_tag_mutability   = "IMMUTABLE"
    mutable_tag_exclusions = ["latest"]
  }

  # The API rejects this. Caught at plan time so it does not read as protection that is
  # not in effect.
  expect_failures = [aws_ecr_repository.this]
}

run "reject_exclusion_mode_without_exclusions" {
  command = plan

  variables {
    image_tag_mutability   = "IMMUTABLE_WITH_EXCLUSION"
    mutable_tag_exclusions = []
  }

  # Identical in behaviour to plain IMMUTABLE, and misleading to read.
  expect_failures = [aws_ecr_repository.this]
}

run "reject_more_than_five_exclusions" {
  command = plan

  variables {
    image_tag_mutability   = "IMMUTABLE_WITH_EXCLUSION"
    mutable_tag_exclusions = ["a", "b", "c", "d", "e", "f"]
  }

  expect_failures = [var.mutable_tag_exclusions]
}

# ── Encryption ───────────────────────────────────────────────────────────────

run "kms_key_switches_encryption_type" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-2:718438899462:key/abcd1234-ab12-cd34-ef56-abcdef123456"
  }

  assert {
    condition     = one(aws_ecr_repository.this.encryption_configuration).encryption_type == "KMS"
    error_message = "supplying a key must switch encryption_type to KMS; AES256 with a key set is silently ignored."
  }

  assert {
    condition     = output.inventory.encrypted_with_cmk == true
    error_message = "inventory should record that a customer-managed key is in use."
  }
}

run "reject_key_alias_instead_of_arn" {
  command = plan

  variables {
    kms_key_arn = "alias/eaf-ecr"
  }

  expect_failures = [var.kms_key_arn]
}

# ── Cross-account pull ───────────────────────────────────────────────────────

run "no_repository_policy_unless_principals_are_named" {
  command = plan

  # A principal in the same account pulls with its own IAM permissions. A repository
  # policy here would be redundant, and an empty one is worse than absent.
  assert {
    condition     = length(aws_ecr_repository_policy.this) == 0
    error_message = "no repository policy should exist when no principals are given."
  }
}

run "repository_policy_grants_pull_only" {
  command = plan

  variables {
    pull_principals = ["arn:aws:iam::679090980132:root"]
  }

  assert {
    condition     = length(aws_ecr_repository_policy.this) == 1
    error_message = "a repository policy should be created when principals are named."
  }

  # ecr:GetAuthorizationToken is an account-level action that a repository policy cannot
  # grant. Listing it would look like it did something.
  assert {
    condition     = !strcontains(one(aws_ecr_repository_policy.this).policy, "GetAuthorizationToken")
    error_message = "GetAuthorizationToken cannot be granted by a repository policy and must not be listed."
  }

  # And nothing that permits a push.
  assert {
    condition = !anytrue([
      for a in ["PutImage", "InitiateLayerUpload", "UploadLayerPart", "CompleteLayerUpload"] :
      strcontains(one(aws_ecr_repository_policy.this).policy, a)
    ])
    error_message = "a pull policy must not grant any push action."
  }
}

# ── Rejections ───────────────────────────────────────────────────────────────

run "reject_uppercase_name" {
  command = plan

  variables {
    name = "EAF/Agent"
  }

  expect_failures = [var.name]
}

run "reject_single_character_name" {
  command = plan

  variables {
    name = "a"
  }

  expect_failures = [var.name]
}

run "accept_a_slashed_name" {
  command = plan

  variables {
    name = "tools/firecrawl-playwright"
  }

  # A slash is a naming convention, not a hierarchy. This is one repository.
  assert {
    condition     = aws_ecr_repository.this.name == "tools/firecrawl-playwright"
    error_message = "a slashed repository name should be accepted as-is."
  }
}

# ── Inventory ────────────────────────────────────────────────────────────────

run "inventory_reports_whether_destroy_can_complete" {
  command = plan

  variables {
    force_delete = true
  }

  # force_delete decides whether `terraform destroy` finishes. False on a repository
  # holding images means the destroy fails partway, leaving the rest of the layer standing
  # and billing.
  assert {
    condition     = output.inventory.destroyable_with_images == true
    error_message = "inventory must report whether the repository can be destroyed with images present."
  }
}
