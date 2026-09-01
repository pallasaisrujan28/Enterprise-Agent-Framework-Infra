# Unit tests for modules/k8s-namespace.
#
# command = plan, mocked provider, no cluster and no credentials.

mock_provider "kubernetes" {}

variables {
  name = "eaf"
}

run "namespace_is_created_with_managed_by_labels" {
  command = plan

  assert {
    condition     = kubernetes_namespace_v1.this.metadata[0].name == "eaf"
    error_message = "namespace name should be passed through."
  }

  assert {
    condition     = kubernetes_namespace_v1.this.metadata[0].labels["app.kubernetes.io/managed-by"] == "terraform"
    error_message = "the namespace should record what manages it, so an unmanaged one is visible from kubectl."
  }
}

# ── The enforcement trap ─────────────────────────────────────────────────────
#
# These are the reason this module exists rather than a bare kubernetes_namespace_v1.

run "no_policy_is_created_when_nothing_would_enforce_it" {
  command = plan

  variables {
    default_deny_ingress    = true
    network_policy_enforced = false
  }

  # THE POINT. A NetworkPolicy with no enforcer is stored by the API server, listed by
  # kubectl, shown by describe as selecting every pod, and ignored. It looks like
  # protection. Creating one in that state is worse than creating none, because it stops
  # anyone asking the question.
  assert {
    condition     = length(kubernetes_network_policy_v1.default_deny_ingress) == 0
    error_message = "no policy should be created when the cluster has no enforcer — an inert policy reads as protection."
  }

  # And the gap must be visible without reading Terraform.
  assert {
    condition     = kubernetes_namespace_v1.this.metadata[0].labels["eaf.io/network-policy"] == "NOT-ENFORCED-no-enforcer-in-cluster"
    error_message = "the namespace label must say the policy was skipped and why."
  }

  assert {
    condition     = output.inventory.ingress_actually_restricted == false
    error_message = "the inventory must not claim ingress is restricted when no policy exists."
  }

  # Requested and created must be distinguishable, or the record cannot show the gap.
  assert {
    condition = (
      output.inventory.default_deny_ingress_requested == true &&
      output.inventory.default_deny_ingress_created == false
    )
    error_message = "the inventory must record that a policy was asked for and not created."
  }
}

run "policy_is_created_when_the_cluster_enforces" {
  command = plan

  variables {
    default_deny_ingress    = true
    network_policy_enforced = true
  }

  assert {
    condition     = length(kubernetes_network_policy_v1.default_deny_ingress) == 1
    error_message = "a policy should be created when the cluster enforces NetworkPolicy."
  }

  # An empty pod_selector selects EVERY pod in the namespace — that is deliberate, and it
  # is what makes this a default rather than a targeted rule. An empty selector renders as
  # a present block with null match_labels, not as an empty map, so this checks the block
  # exists and carries no selector.
  assert {
    condition = (
      length(one(kubernetes_network_policy_v1.default_deny_ingress).spec[0].pod_selector) == 1 &&
      one(kubernetes_network_policy_v1.default_deny_ingress).spec[0].pod_selector[0].match_labels == null
    )
    error_message = "the default-deny policy must select every pod, which means a pod_selector with no match_labels."
  }

  assert {
    condition     = output.inventory.ingress_actually_restricted == true
    error_message = "inventory should report ingress as restricted."
  }
}

run "egress_is_deliberately_not_denied" {
  command = plan

  variables {
    network_policy_enforced = true
  }

  # Denying egress as well would stop pods reaching the cluster's DNS, and the symptom is
  # every hostname failing to resolve — which reads as broken CoreDNS rather than as a
  # NetworkPolicy. Egress restriction belongs with a policy that also permits port 53 to
  # kube-system.
  assert {
    condition = (
      join(",", one(kubernetes_network_policy_v1.default_deny_ingress).spec[0].policy_types) == "Ingress"
    )
    error_message = "only Ingress should be denied; denying Egress here would break DNS in a way that looks unrelated."
  }
}

run "no_policy_when_default_deny_is_switched_off" {
  command = plan

  variables {
    default_deny_ingress    = false
    network_policy_enforced = true
  }

  assert {
    condition     = length(kubernetes_network_policy_v1.default_deny_ingress) == 0
    error_message = "no policy when default_deny_ingress is false."
  }

  assert {
    condition     = kubernetes_namespace_v1.this.metadata[0].labels["eaf.io/network-policy"] == "none"
    error_message = "the label should distinguish 'not asked for' from 'asked for but not enforced'."
  }
}

# ── Quota and limits ─────────────────────────────────────────────────────────

run "no_quota_or_limits_by_default" {
  command = plan

  assert {
    condition = (
      length(kubernetes_resource_quota_v1.this) == 0 &&
      length(kubernetes_limit_range_v1.this) == 0
    )
    error_message = "a namespace should not get a quota or limits unless asked."
  }
}

run "quota_and_limits_are_applied_when_given" {
  command = plan

  variables {
    resource_quota = { "persistentvolumeclaims" = "4" }
    limit_range = {
      default_request_cpu    = "250m"
      default_request_memory = "1Gi"
      default_limit_memory   = "4Gi"
    }
  }

  assert {
    condition     = one(kubernetes_resource_quota_v1.this).spec[0].hard["persistentvolumeclaims"] == "4"
    error_message = "the quota should be applied. A PVC limit matters most: each one becomes a billed EBS volume."
  }

  assert {
    condition = (
      one(kubernetes_limit_range_v1.this).spec[0].limit[0].default_request["memory"] == "1Gi"
    )
    error_message = "default requests should be applied."
  }

  # A limit that was not supplied must be absent rather than empty or zero — an explicit
  # cpu limit of 0 would be a very different thing from no cpu limit.
  assert {
    condition = (
      !contains(keys(one(kubernetes_limit_range_v1.this).spec[0].limit[0].default), "cpu")
    )
    error_message = "an omitted limit must be absent, not set to an empty value."
  }
}

# ── Rejections ───────────────────────────────────────────────────────────────

run "reject_kube_prefixed_namespace" {
  command = plan

  variables {
    name = "kube-system"
  }

  # Managing a kube-* namespace means fighting the control plane for ownership of it.
  expect_failures = [var.name]
}

run "reject_invalid_namespace_name" {
  command = plan

  variables {
    name = "EAF_Prod"
  }

  expect_failures = [var.name]
}
