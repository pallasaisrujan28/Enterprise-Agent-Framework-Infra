# Unit tests for modules/account-baseline.
#
# command = plan throughout. No credentials, no resources, a few seconds.
# Verified to pass with AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# AWS_SESSION_TOKEN, AWS_PROFILE and AWS_DEFAULT_REGION all unset.
#
# THE POINT OF THE FIRST TEST. This module is live in two accounts and its state
# cannot be reached from a workstation, so a plan against real state is not available
# to confirm that introducing org_prefix renames nothing. An IAM policy or role name
# is immutable — changing one forces replacement, and the boundary here is referenced
# by the workloads layer. So the exact live names are pinned as literals below. If a
# future edit changes how a name is built, this fails offline rather than proposing a
# replacement against a real account.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "718438899462"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  # aws_iam_policy_document is computed BY the provider, so mock_provider stubs it and
  # the stubbed `json` is not a valid policy — aws_iam_policy then fails validation at
  # plan. Supplying a valid empty document gets the plan through.
  #
  # The consequence is honest and worth stating: these tests cannot assert on the
  # RENDERED policy JSON, because under a mocked provider it is this placeholder. What
  # they assert instead is the generated names and the constructed boundary ARN, read
  # from output.inventory, which are plain locals and so are real. Whether the rendered
  # document is well-formed is covered by terraform validate and by apply itself.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  org_prefix                 = "eaf"
  account_name               = "EAF-DEV"
  environment                = "dev"
  region                     = "eu-west-2"
  github_repository          = "pallasaisrujan28/Enterprise-Agent-Framework-Infra"
  github_repository_owner_id = "194785418"
  github_repository_id       = "1324052608"
  budget_alert_email         = "platform@example.com"
}

# ── The names must not move ──────────────────────────────────────────────────

run "generated_names_match_the_live_resources" {
  command = plan

  assert {
    condition     = aws_iam_policy.workload_boundary.name == "eaf-workload-boundary"
    error_message = "boundary renamed to ${aws_iam_policy.workload_boundary.name} — an IAM policy name change forces replacement, and the workloads layer references this one."
  }

  assert {
    condition     = aws_iam_role.workload_ci.name == "eaf-workload-ci-role"
    error_message = "CI role renamed to ${aws_iam_role.workload_ci.name} — forces replacement of a role that survives workload teardown."
  }

  assert {
    condition     = aws_budgets_budget.monthly.name == "eaf-EAF-DEV-monthly"
    error_message = "budget renamed to ${aws_budgets_budget.monthly.name}."
  }
}

run "boundary_arn_cannot_drift_from_the_boundary_name" {
  command = plan

  # The two statements that name the boundary sit inside the boundary's OWN policy
  # document, so they cannot reference aws_iam_policy.workload_boundary.arn — that is a
  # self-reference and Terraform rejects the graph as a cycle. The ARN is therefore
  # constructed from local.boundary_name, the same local that names the resource.
  #
  # This asserts what the missing attribute reference would have guaranteed: that the
  # constructed ARN and the policy's actual name cannot disagree.
  assert {
    condition = (
      output.inventory.workload_boundary.arn
      == "arn:aws:iam::718438899462:policy/${aws_iam_policy.workload_boundary.name}"
    )
    error_message = "constructed boundary ARN ${output.inventory.workload_boundary.arn} does not match the policy's name ${aws_iam_policy.workload_boundary.name}."
  }

  assert {
    condition     = output.inventory.workload_boundary.name == aws_iam_policy.workload_boundary.name
    error_message = "the name in the inventory output is not the name on the resource."
  }
}

run "org_prefix_reaches_every_generated_name" {
  command = plan

  variables {
    org_prefix = "acme"
  }

  # Proves the prefix is genuinely threaded through rather than defaulted somewhere,
  # which is what made this module unusable by a second organisation.
  assert {
    condition = alltrue([
      aws_iam_policy.workload_boundary.name == "acme-workload-boundary",
      aws_iam_role.workload_ci.name == "acme-workload-ci-role",
      aws_budgets_budget.monthly.name == "acme-EAF-DEV-monthly",
    ])
    error_message = "org_prefix did not reach every generated name."
  }

  # And the constructed ARN follows the rename rather than being left behind.
  assert {
    condition     = output.inventory.workload_boundary.arn == "arn:aws:iam::718438899462:policy/acme-workload-boundary"
    error_message = "renaming left a stale boundary ARN: ${output.inventory.workload_boundary.arn}"
  }

  assert {
    condition     = !strcontains(jsonencode(output.inventory), "eaf-")
    error_message = "a hardcoded eaf- name survives in the generated inventory."
  }
}

# ── The OIDC issuer is derived, not restated ─────────────────────────────────

run "oidc_condition_keys_follow_the_created_provider" {
  command = plan

  variables {
    # A GitHub Enterprise Server appliance.
    github_oidc_issuer_url = "https://github.example.com/_services/token"
  }

  assert {
    condition     = aws_iam_openid_connect_provider.github.url == "https://github.example.com/_services/token"
    error_message = "provider URL not taken from the input."
  }

  # The condition-key prefix is derived from that URL rather than written out again.
  # The failure this prevents is silent: a trust policy naming a different issuer than
  # the provider it federates is valid JSON, applies cleanly, and never matches.
  assert {
    condition     = output.inventory.github_oidc.issuer_host == "github.example.com/_services/token"
    error_message = "issuer host not derived from the configured provider URL, got ${output.inventory.github_oidc.issuer_host}."
  }
}

run "immutable_subject_is_emitted" {
  command = plan

  assert {
    condition = (
      output.inventory.github_oidc.subject
      == "repo:pallasaisrujan28@194785418/Enterprise-Agent-Framework-Infra@1324052608:ref:refs/heads/*"
    )
    error_message = "the OIDC subject is not in the immutable owner@id/repo@id form, which silently never matches."
  }
}

# ── Rejections ───────────────────────────────────────────────────────────────

run "reject_bad_org_prefix" {
  command = plan

  variables {
    org_prefix = "EAF_Platform"
  }

  expect_failures = [var.org_prefix]
}

run "reject_issuer_url_without_scheme" {
  command = plan

  variables {
    # aws_iam_openid_connect_provider requires the scheme. Without this validation the
    # failure arrives from the AWS API at apply time.
    github_oidc_issuer_url = "token.actions.githubusercontent.com"
  }

  expect_failures = [var.github_oidc_issuer_url]
}

run "reject_unknown_environment" {
  command = plan

  variables {
    environment = "sandbox"
  }

  expect_failures = [var.environment]
}
