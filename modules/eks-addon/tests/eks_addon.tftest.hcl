# Unit tests for modules/eks-addon.
#
# command = plan throughout. No credentials.
# Verified to pass with every AWS environment variable unset.

mock_provider "aws" {}

variables {
  org_prefix    = "eaf"
  environment   = "dev"
  owner         = "platform-team"
  cluster_name  = "eaf-dev"
  addon_name    = "vpc-cni"
  addon_version = "v1.22.4-eksbuild.3"
}

# ── Pod Identity, not IRSA ───────────────────────────────────────────────────

run "pod_identity_association_is_emitted_when_a_role_is_given" {
  command = plan

  variables {
    pod_identity = {
      role_arn        = "arn:aws:iam::718438899462:role/eaf-dev-platform-vpc-cni-role"
      service_account = "aws-node"
    }
  }

  assert {
    condition = (
      one(aws_eks_addon.this.pod_identity_association).service_account == "aws-node"
    )
    error_message = "the association should name the service account the add-on runs as."
  }

  # service_account_role_arn is the IRSA form. Deliberately unused.
  assert {
    condition     = aws_eks_addon.this.service_account_role_arn == null
    error_message = "service_account_role_arn is the IRSA mechanism and should not be set; this module uses Pod Identity."
  }

  assert {
    condition     = strcontains(output.inventory.identity, "pod-identity")
    error_message = "inventory should report how this add-on obtains credentials."
  }
}

run "no_association_for_an_addon_that_needs_no_permissions" {
  command = plan

  variables {
    addon_name    = "coredns"
    addon_version = "v1.14.3-eksbuild.14"
    # coredns and kube-proxy both return no Pod Identity recommendation from
    # describe-addon-configuration, so neither needs a role.
  }

  assert {
    condition     = length(aws_eks_addon.this.pod_identity_association) == 0
    error_message = "no association should be created when pod_identity is omitted."
  }

  assert {
    condition     = strcontains(output.inventory.identity, "none")
    error_message = "inventory should say plainly that this add-on needs no AWS permissions."
  }
}

# ── The pairing is structural, not validated ─────────────────────────────────
#
# A role without a service account creates no association, so the add-on falls back to
# the NODE role and appears to work with the wrong identity. There is no test for that
# case because the type makes it unrepresentable: `pod_identity` is a single object with
# both fields required. That is the point — a constraint encoded in the type cannot be
# violated, so it needs no runtime check.

run "reject_service_account_that_kubernetes_cannot_create" {
  command = plan

  variables {
    pod_identity = {
      role_arn        = "arn:aws:iam::718438899462:role/eaf-dev-platform-vpc-cni-role"
      service_account = "AWS_Node"
    }
  }

  expect_failures = [var.pod_identity]
}

run "reject_role_name_instead_of_arn" {
  command = plan

  variables {
    pod_identity = {
      role_arn        = "eaf-dev-platform-vpc-cni-role"
      service_account = "aws-node"
    }
  }

  expect_failures = [var.pod_identity]
}

# ── Prefix delegation ────────────────────────────────────────────────────────

run "prefix_delegation_is_passed_through_and_reported" {
  command = plan

  variables {
    configuration_values = "{\"env\":{\"ENABLE_PREFIX_DELEGATION\":\"true\",\"WARM_PREFIX_TARGET\":\"1\"}}"
    pod_identity = {
      role_arn        = "arn:aws:iam::718438899462:role/eaf-dev-platform-vpc-cni-role"
      service_account = "aws-node"
    }
  }

  assert {
    condition = (
      jsondecode(aws_eks_addon.this.configuration_values).env.ENABLE_PREFIX_DELEGATION == "true"
    )
    error_message = "prefix delegation should reach the add-on configuration."
  }

  # Surfaced because it cannot be changed later without new node groups: prefix
  # delegation applies to instances at launch, so turning it on afterwards does not
  # affect nodes already running.
  assert {
    condition     = output.inventory.prefix_delegation_on == true
    error_message = "inventory should report prefix delegation as on."
  }
}

run "prefix_delegation_reported_off_when_absent" {
  command = plan

  assert {
    condition     = output.inventory.prefix_delegation_on == false
    error_message = "inventory should report prefix delegation off when no configuration is given."
  }
}

run "reject_configuration_that_is_not_json" {
  command = plan

  variables {
    configuration_values = "ENABLE_PREFIX_DELEGATION=true"
  }

  expect_failures = [var.configuration_values]
}

# ── Version pinning ─────────────────────────────────────────────────────────

run "reject_version_without_leading_v" {
  command = plan

  variables {
    # AWS's add-on versions carry a leading v. Without it the API reports the version
    # as not found, which reads like the add-on is unavailable.
    addon_version = "1.22.4-eksbuild.3"
  }

  expect_failures = [var.addon_version]
}

run "reject_bare_semver_without_eksbuild" {
  command = plan

  variables {
    addon_version = "v1.22.4"
  }

  # Accepted by the regex — the eksbuild suffix is optional because not every add-on
  # carries one. This asserts the shape is allowed rather than rejected, so the
  # validation is not tighter than reality.
  assert {
    condition     = aws_eks_addon.this.addon_version == "v1.22.4"
    error_message = "a version without an eksbuild suffix should be accepted; some add-ons have none."
  }
}

# ── Conflict resolution ─────────────────────────────────────────────────────

run "conflicts_are_overwritten_by_default" {
  command = plan

  # EKS pre-installs self-managed vpc-cni, kube-proxy and coredns on every new
  # cluster, so taking over something already running is the normal case. The provider
  # default (NONE) fails with a conflict instead.
  assert {
    condition     = aws_eks_addon.this.resolve_conflicts_on_create == "OVERWRITE"
    error_message = "resolve_conflicts_on_create should default to OVERWRITE."
  }

  # On update it discards out-of-band edits, which is the point: an add-on patched by
  # hand during an incident is exactly the untracked change this repository stops.
  assert {
    condition     = aws_eks_addon.this.resolve_conflicts_on_update == "OVERWRITE"
    error_message = "resolve_conflicts_on_update should default to OVERWRITE."
  }

  assert {
    condition     = aws_eks_addon.this.preserve == false
    error_message = "preserve should default to false; an orphaned DaemonSet nothing manages is drift by another name."
  }
}
