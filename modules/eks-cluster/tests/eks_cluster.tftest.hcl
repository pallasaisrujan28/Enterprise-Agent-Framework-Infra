# Unit tests for modules/eks-cluster.
#
# command = plan throughout. No credentials, no resources.
# Verified to pass with AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN,
# AWS_PROFILE, AWS_DEFAULT_REGION and AWS_REGION all unset.

mock_provider "aws" {}

variables {
  org_prefix         = "eaf"
  environment        = "dev"
  owner              = "platform-team"
  kubernetes_version = "1.36"
  cluster_role_arn   = "arn:aws:iam::718438899462:role/eaf-dev-platform-eks-cluster-role"
  subnet_ids         = ["subnet-aaa", "subnet-bbb"]

  access_entries = {
    deployer = {
      principal_arn = "arn:aws:iam::718438899462:role/eaf-baseline-dev-role"
      policies = [{
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        scope_type = "cluster"
      }]
    }
  }
}

# ── The setting AWS gets wrong by default ─────────────────────────────────────

run "authentication_mode_is_api_not_the_deprecated_configmap" {
  command = plan

  # AWS defaults this to CONFIG_MAP for clusters created through the API, SDKs or
  # CloudFormation — which is Terraform's path. CONFIG_MAP is the aws-auth ConfigMap,
  # which AWS has deprecated, and the migration to API is ONE-WAY. Getting it wrong
  # means a new cluster to fix it.
  assert {
    condition     = one(aws_eks_cluster.this.access_config).authentication_mode == "API"
    error_message = "authentication_mode must be API. CONFIG_MAP is deprecated and the change is irreversible."
  }
}

run "creator_admin_bootstrap_is_off_by_default" {
  command = plan

  # An implicit grant to whichever principal ran the apply. It appears as no resource,
  # so "who administers this cluster?" cannot be answered from configuration, and the
  # answer differs depending on who applied. Changing it later REPLACES the cluster.
  assert {
    condition     = one(aws_eks_cluster.this.access_config).bootstrap_cluster_creator_admin_permissions == false
    error_message = "bootstrap_cluster_creator_admin_permissions should default to false so every admin grant is explicit."
  }
}

run "support_type_defaults_to_standard" {
  command = plan

  # Under EXTENDED, a cluster past end-of-standard-support keeps running and quietly
  # starts billing at the extended rate. STANDARD forces an upgrade instead.
  assert {
    condition     = one(aws_eks_cluster.this.upgrade_policy).support_type == "STANDARD"
    error_message = "support_type should default to STANDARD, so reaching end of support forces an upgrade rather than a bill."
  }
}

run "audit_logging_is_on_by_default" {
  command = plan

  # Without audit and authenticator logs, an access-control question has no evidence.
  assert {
    condition = alltrue([
      contains(aws_eks_cluster.this.enabled_cluster_log_types, "audit"),
      contains(aws_eks_cluster.this.enabled_cluster_log_types, "authenticator"),
    ])
    error_message = "audit and authenticator logs should be on by default."
  }
}

# ── A cluster nobody can administer ──────────────────────────────────────────

run "reject_cluster_with_no_administrator" {
  command = plan

  variables {
    # No bootstrap grant, and an entry that only grants namespace-scoped view. Passes
    # a naive "is there an access entry?" check while leaving nobody able to administer
    # anything — and with authentication_mode = API there is no ConfigMap to fall back
    # on. The cluster would be unreachable, fixable only by an out-of-band API call.
    access_entries = {
      viewer = {
        principal_arn = "arn:aws:iam::718438899462:role/some-reader"
        policies = [{
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          scope_type = "namespace"
          namespaces = ["eaf"]
        }]
      }
    }
  }

  expect_failures = [aws_eks_cluster.this]
}

run "reject_no_access_entries_at_all" {
  command = plan

  variables {
    access_entries = {}
  }

  expect_failures = [aws_eks_cluster.this]
}

run "accept_no_access_entries_when_bootstrap_admin_is_explicit" {
  command = plan

  variables {
    access_entries                              = {}
    bootstrap_cluster_creator_admin_permissions = true
  }

  # The implicit grant is allowed, but only when asked for. And it is then reported,
  # because it is otherwise invisible.
  assert {
    condition     = output.inventory.implicit_creator_admin == true
    error_message = "an implicit creator-admin grant must be reported in the inventory."
  }

  assert {
    condition = (
      length(output.inventory.administrators) == 1 &&
      strcontains(one(output.inventory.administrators), "IMPLICIT")
    )
    error_message = "the implicit grant should appear in the administrators list, named as implicit."
  }
}

# ── Access entries ───────────────────────────────────────────────────────────

run "access_entry_and_policy_association_are_separate_resources" {
  command = plan

  # Both are real resources, so `terraform state list` answers "who can reach this
  # cluster?" — which the aws-auth ConfigMap never could.
  assert {
    condition     = length(aws_eks_access_entry.this) == 1
    error_message = "expected one access entry."
  }

  assert {
    condition     = length(aws_eks_access_policy_association.this) == 1
    error_message = "expected one access policy association."
  }

  # Keyed by entry name and policy name, never by index, so adding a policy to one
  # principal cannot renumber another's.
  assert {
    condition     = contains(keys(aws_eks_access_policy_association.this), "deployer/AmazonEKSClusterAdminPolicy")
    error_message = "association key should be entry/policy, got ${join(", ", keys(aws_eks_access_policy_association.this))}"
  }
}

run "cluster_scoped_association_sends_no_namespaces" {
  command = plan

  # A cluster-scoped association must omit namespaces entirely, not send an empty
  # list. The API rejects the latter.
  assert {
    condition = (
      one(aws_eks_access_policy_association.this["deployer/AmazonEKSClusterAdminPolicy"].access_scope).type == "CLUSTER" &&
      one(aws_eks_access_policy_association.this["deployer/AmazonEKSClusterAdminPolicy"].access_scope).namespaces == null
    )
    error_message = "a cluster-scoped association must send type CLUSTER and no namespaces."
  }
}

run "namespace_scope_passes_its_namespaces_through" {
  command = plan

  variables {
    access_entries = {
      deployer = {
        principal_arn = "arn:aws:iam::718438899462:role/eaf-baseline-dev-role"
        policies = [{
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          scope_type = "cluster"
        }]
      }
      dev = {
        principal_arn = "arn:aws:iam::718438899462:role/developer"
        policies = [{
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          scope_type = "namespace"
          namespaces = ["eaf", "tools"]
        }]
      }
    }
  }

  assert {
    condition = (
      join(",", one(aws_eks_access_policy_association.this["dev/AmazonEKSEditPolicy"].access_scope).namespaces) == "eaf,tools"
    )
    error_message = "namespace-scoped association should pass its namespaces through."
  }

  # The cluster admin is still the deployer only — a namespace editor is not an
  # administrator, and the inventory must not blur them.
  assert {
    condition = (
      join(",", output.inventory.administrators) == "arn:aws:iam::718438899462:role/eaf-baseline-dev-role"
    )
    error_message = "only cluster-scoped AmazonEKSClusterAdminPolicy holders are administrators, got ${join(", ", output.inventory.administrators)}"
  }
}

run "reject_namespace_scope_without_namespaces" {
  command = plan

  variables {
    access_entries = {
      deployer = {
        principal_arn = "arn:aws:iam::718438899462:role/eaf-baseline-dev-role"
        policies = [{
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          scope_type = "cluster"
        }]
      }
      broken = {
        principal_arn = "arn:aws:iam::718438899462:role/developer"
        policies = [{
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          scope_type = "namespace"
          # Grants nothing, and reports nothing.
        }]
      }
    }
  }

  expect_failures = [var.access_entries]
}

run "reject_iam_policy_arn_where_an_eks_access_policy_belongs" {
  command = plan

  variables {
    access_entries = {
      deployer = {
        principal_arn = "arn:aws:iam::718438899462:role/eaf-baseline-dev-role"
        policies = [{
          # An IAM policy ARN. Looks plausible; the API rejects it with a message that
          # does not say which of the two kinds it wanted.
          policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
          scope_type = "cluster"
        }]
      }
    }
  }

  expect_failures = [var.access_entries]
}

# ── Endpoint exposure ────────────────────────────────────────────────────────

run "public_access_cidrs_are_not_sent_when_public_access_is_off" {
  command = plan

  variables {
    endpoint_public_access = false
  }

  # Sending public_access_cidrs while public access is off is rejected by the API, so
  # the module passes null instead. The resource attribute itself is provider-computed
  # and therefore unknown at plan, so this asserts through the inventory — which is
  # derived from the inputs and is known.
  assert {
    condition     = length(output.inventory.public_access_cidrs) == 0
    error_message = "no public CIDRs should be reported when endpoint_public_access is false."
  }

  assert {
    condition     = output.inventory.publicly_reachable == false
    error_message = "inventory should report the cluster as not publicly reachable."
  }

  assert {
    condition     = one(aws_eks_cluster.this.vpc_config).endpoint_public_access == false
    error_message = "endpoint_public_access should be false."
  }
}

run "inventory_flags_a_wide_open_endpoint" {
  command = plan

  # The default IS 0.0.0.0/0, matching AWS. The point is that it is reported rather
  # than buried, so a reviewer sees it without reading the configuration.
  assert {
    condition     = output.inventory.publicly_reachable == true
    error_message = "a cluster open to 0.0.0.0/0 must be flagged as publicly reachable."
  }
}

# ── Rejections ───────────────────────────────────────────────────────────────

run "reject_single_subnet" {
  command = plan

  variables {
    subnet_ids = ["subnet-aaa"]
  }

  expect_failures = [var.subnet_ids]
}

run "reject_patch_version" {
  command = plan

  variables {
    # EKS takes a minor version and manages patches through the platform version.
    kubernetes_version = "1.36.2"
  }

  expect_failures = [var.kubernetes_version]
}

run "reject_role_name_instead_of_arn" {
  command = plan

  variables {
    cluster_role_arn = "eaf-dev-platform-eks-cluster-role"
  }

  expect_failures = [var.cluster_role_arn]
}

run "reject_unknown_log_type" {
  command = plan

  variables {
    enabled_cluster_log_types = ["api", "kubelet"]
  }

  expect_failures = [var.enabled_cluster_log_types]
}

run "reject_bad_org_prefix" {
  command = plan

  variables {
    org_prefix = "EAF_Platform"
  }

  expect_failures = [var.org_prefix]
}
