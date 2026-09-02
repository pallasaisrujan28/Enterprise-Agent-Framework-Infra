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

run "access_scope_type_is_lowercase" {
  command = plan

  # THIS TEST EXISTS BECAUSE ITS PREDECESSOR ASSERTED THE OPPOSITE AND PASSED.
  #
  # The first version asserted `type == "CLUSTER"`, matching an upper() in the module.
  # Both agreed with each other and neither agreed with AWS. The apply failed after the
  # cluster had already been created:
  #
  #   InvalidParameterException: accessScope type must be one of [namespace, cluster]
  #
  # The provider passes this value through verbatim; it does not normalise case. Pinned
  # as a literal lowercase string rather than derived from the input, so a future
  # upper() or title() in the module fails here instead of at apply.
  assert {
    condition     = one(aws_eks_access_policy_association.this["deployer/AmazonEKSClusterAdminPolicy"].access_scope).type == "cluster"
    error_message = "access_scope.type must be lowercase \"cluster\"; the EKS API rejects \"CLUSTER\"."
  }

  # A cluster-scoped association must omit namespaces entirely, not send an empty list.
  assert {
    condition     = one(aws_eks_access_policy_association.this["deployer/AmazonEKSClusterAdminPolicy"].access_scope).namespaces == null
    error_message = "a cluster-scoped association must send no namespaces."
  }
}

run "mixed_case_input_is_normalised_down" {
  command = plan

  variables {
    access_entries = {
      deployer = {
        principal_arn = "arn:aws:iam::718438899462:role/eaf-baseline-dev-role"
        # The variable validation accepts any case, so the module must normalise. A
        # caller writing "Cluster" should not produce an apply-time API rejection.
        policies = [{
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          scope_type = "CLUSTER"
        }]
      }
    }
  }

  assert {
    condition     = one(aws_eks_access_policy_association.this["deployer/AmazonEKSClusterAdminPolicy"].access_scope).type == "cluster"
    error_message = "an upper-case scope_type input must be normalised to lowercase before it reaches the API."
  }

  # And the precondition that looks for a cluster admin must still recognise it, or a
  # caller writing "CLUSTER" would be told the cluster has no administrator.
  assert {
    condition     = length(output.inventory.administrators) == 1
    error_message = "the cluster-admin check must survive a mixed-case scope_type input."
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

# ── The log group, and the leak that existed before it ────────────────────────
#
# Enabling log types without owning the group is not "no log group". EKS creates one at a
# fixed path with no retention, absent from state, and every teardown leaves it behind.
# Measured on this account at 931.8 MB and NEVER EXPIRES before this was added.

run "the_log_group_is_owned_and_bounded" {
  command = plan

  variables {
    enabled_cluster_log_types = ["api", "audit", "authenticator"]
    log_retention_days        = 30
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.cluster) == 1
    error_message = "the log group must be created. Left to EKS it has no retention and no state, so nothing bounds it and no destroy removes it."
  }

  assert {
    condition     = one(aws_cloudwatch_log_group.cluster).retention_in_days == 30
    error_message = "retention must be set. The absent-field default is keep-forever."
  }

  # EKS writes to this exact path and cannot be told otherwise, so a different name here
  # would leave the real group unmanaged while creating an empty one alongside it.
  assert {
    condition     = one(aws_cloudwatch_log_group.cluster).name == "/aws/eks/eaf-dev/cluster"
    error_message = "the name must be /aws/eks/<cluster>/cluster, which is where EKS publishes."
  }

  assert {
    condition     = output.inventory.logs_kept_forever == false
    error_message = "the inventory must report that logs are bounded."
  }
}

run "no_log_group_when_no_log_types_are_enabled" {
  command = plan

  variables {
    enabled_cluster_log_types = []
  }

  # Nothing writes, so a group would be an empty resource that still has to be destroyed.
  assert {
    condition     = length(aws_cloudwatch_log_group.cluster) == 0
    error_message = "with no log types there is nothing to store, so no group should exist."
  }

  assert {
    condition     = output.inventory.logs_kept_forever == false
    error_message = "no logs at all cannot be logs kept forever."
  }
}

run "keeping_logs_forever_has_to_be_asked_for" {
  command = plan

  variables {
    enabled_cluster_log_types = ["api"]
    log_retention_days        = null
  }

  # null is permitted, because some environments genuinely need indefinite retention. What
  # this module removes is arriving there by omission.
  assert {
    condition     = one(aws_cloudwatch_log_group.cluster).retention_in_days == null
    error_message = "a null retention must reach the provider as null, which is how CloudWatch expresses keep-forever."
  }

  assert {
    condition     = output.inventory.logs_kept_forever == true
    error_message = "the inventory must say so plainly when logs never expire. That is the state that produced the leak."
  }
}

run "declining_to_manage_the_group_is_reported_as_unbounded" {
  command = plan

  variables {
    enabled_cluster_log_types = ["api", "audit"]
    manage_log_group          = false
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.cluster) == 0
    error_message = "no group is created when the caller declines to manage it."
  }

  # The honest consequence: EKS will create it, with no retention, owned by nothing.
  assert {
    condition     = output.inventory.logs_kept_forever == true
    error_message = "logs are published but nothing bounds them, and the inventory must not describe that as managed."
  }

  assert {
    condition     = output.inventory.log_group_managed_here == false
    error_message = "the inventory must not claim ownership of a group this module did not create."
  }
}

run "reject_a_retention_cloudwatch_does_not_accept" {
  command = plan

  variables {
    enabled_cluster_log_types = ["api"]
    log_retention_days        = 45
  }

  # CloudWatch Logs takes an enumerated set, not any integer. 45 applies cleanly in a plan
  # and is rejected at apply time, which is the wrong place to find out.
  expect_failures = [var.log_retention_days]
}
