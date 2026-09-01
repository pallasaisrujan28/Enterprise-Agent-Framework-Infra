# A namespace plus its baseline: default-deny ingress, and optionally a quota and
# default container limits.
#
# THE NETWORK POLICY TRAP, which this module refuses to walk into silently.
#
# A NetworkPolicy is an object the API server stores whether or not anything enforces it.
# With no enforcer running, `kubectl get networkpolicy` lists your default-deny rule,
# `kubectl describe` shows it selecting every pod, and traffic flows exactly as before.
# It looks configured. It does nothing.
#
# On EKS the enforcer is the Amazon VPC CNI's node agent, and it is OFF unless the add-on
# is configured with enableNetworkPolicy = "true". Verified on this cluster before the
# flag was set: the aws-eks-nodeagent container was running, but with
# `--enable-network-policy=false`. The container's presence proves nothing.
#
# So `network_policy_enforced` is a required assertion from the caller. When it is false
# the module creates NO policy and says so in a namespace label, rather than leaving
# something that reads as protection.

locals {
  policy_state = var.default_deny_ingress ? (
    var.network_policy_enforced ? "enforced" : "NOT-ENFORCED-no-enforcer-in-cluster"
  ) : "none"

  create_policy = var.default_deny_ingress && var.network_policy_enforced
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name        = var.name
    annotations = var.annotations

    labels = merge(var.labels, {
      "app.kubernetes.io/managed-by" = "terraform"
      "eaf.io/module"                = "k8s-namespace"

      # The namespace's own name as a label. Kubernetes adds
      # kubernetes.io/metadata.name automatically, but a NetworkPolicy in ANOTHER
      # namespace needs a namespaceSelector to permit traffic from this one, and
      # selecting on a label you control is clearer than relying on the automatic one.
      "eaf.io/namespace" = var.name

      # Recorded so the gap is visible from `kubectl get ns --show-labels` rather than
      # only from Terraform. A default-deny policy that nothing enforces is worth being
      # able to see.
      "eaf.io/network-policy" = local.policy_state
    })
  }
}

# ── Default deny ingress ──────────────────────────────────────────────────────

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  count = local.create_policy ? 1 : 0

  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.this.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "eaf.io/module"                = "k8s-namespace"
    }
  }

  spec {
    # An empty pod_selector selects EVERY pod in the namespace. That is the point.
    pod_selector {}

    # Ingress listed as a policy type with no rules below it means "deny all ingress".
    # Egress is deliberately NOT listed: denying egress too would stop pods reaching the
    # cluster's DNS, and the symptom is every hostname failing to resolve — which reads
    # as a broken CoreDNS rather than a NetworkPolicy. Egress restrictions belong with a
    # policy that also permits port 53 to kube-system.
    policy_types = ["Ingress"]
  }
}

# ── Quota ─────────────────────────────────────────────────────────────────────

resource "kubernetes_resource_quota_v1" "this" {
  count = var.resource_quota == null ? 0 : 1

  metadata {
    name      = "namespace-quota"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    hard = var.resource_quota
  }
}

# ── Default container requests and limits ─────────────────────────────────────
#
# Worth pairing with a quota. A container that declares no request counts as ZERO against
# a quota while still occupying real capacity on a node, so without defaults the quota
# stops describing what is actually running.

resource "kubernetes_limit_range_v1" "this" {
  count = var.limit_range == null ? 0 : 1

  metadata {
    name      = "default-limits"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    limit {
      type = "Container"

      default_request = merge(
        try(var.limit_range.default_request_cpu, null) == null ? {} : { cpu = var.limit_range.default_request_cpu },
        try(var.limit_range.default_request_memory, null) == null ? {} : { memory = var.limit_range.default_request_memory },
      )

      default = merge(
        try(var.limit_range.default_limit_cpu, null) == null ? {} : { cpu = var.limit_range.default_limit_cpu },
        try(var.limit_range.default_limit_memory, null) == null ? {} : { memory = var.limit_range.default_limit_memory },
      )
    }
  }
}
