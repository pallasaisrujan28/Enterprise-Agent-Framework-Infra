# L3 — apps. Currently: Neo4j, the memory layer's datastore.
#
# WHAT THIS LAYER IS FOR, and what it deliberately does not contain yet.
#
# Neo4j is the first stateful workload in the platform, so it is also the first end-to-end
# exercise of dynamic volume provisioning through the EBS CSI driver — the add-on that timed
# out repeatedly in the configuration this replaces. "The release became ready" is therefore
# a real signal here, not a formality, which is why the module waits.
#
# Graphiti is NOT here. It needs an LLM and an embedding model configured at startup, and the
# embedding choice cannot be changed later without re-embedding the whole graph. Neo4j is
# useful on its own; Graphiti without a consumer is a pod idling on a blind decision.
#
# The agent workload is also absent, and for a different reason: it cannot start. Verified in
# the application repository — the entrypoint and the declared console script both reference
# modules that do not exist.

# ── The memory namespace must exist and must actually deny traffic ────────────
#
# Two checks against the cluster-addons layer, both of which fail here with a clear message
# rather than later against the Kubernetes API with an unclear one.
check "memory_namespace_is_owned_by_cluster_addons" {
  assert {
    condition     = contains(local.namespace_names, var.memory_namespace)
    error_message = "namespace '${var.memory_namespace}' is not owned by the cluster-addons layer. Helm must not create it: a Helm-created namespace has no default-deny NetworkPolicy, no PVC quota and no LimitRange, and looks identical in `kubectl get ns`."
  }
}

check "network_policy_is_actually_enforced" {
  assert {
    condition = local.network_policy_enforced
    error_message = join(" ", [
      "NetworkPolicy is not enforced in '${var.memory_namespace}' (state: ${local.network_policy_state}).",
      "Neo4j will still deploy with authentication on, but the namespace's default-deny is inert,",
      "so the database is reachable from anywhere in the cluster.",
      "Enforcement is the vpc-cni add-on's enableNetworkPolicy setting, in the platform layer.",
    ])
  }
}

# ── Neo4j ─────────────────────────────────────────────────────────────────────

module "neo4j" {
  source = "../../../modules/neo4j"

  name      = "neo4j"
  namespace = var.memory_namespace

  chart_version = var.neo4j_chart_version

  # Named, not inherited from whichever class happens to be default — and read from the layer
  # that created it rather than restated here.
  storage_class_name = local.storage_class_name
  storage_size       = var.neo4j_storage_size

  # An m6i.large has two vCPUs and about 1930m allocatable. The chart's default request of
  # 1000m would take over half of one node before anything else is placed, and Property 9 is
  # about exactly this arithmetic.
  cpu_request    = "500m"
  memory_request = "2Gi"

  # Empty until something consumes the graph. Graphiti lands in this same namespace, which
  # `allow_same_namespace` already covers.
  allowed_client_namespaces = var.neo4j_client_namespaces
  allow_same_namespace      = true

  # Read from the cluster-addons layer, not asserted independently. If the two disagreed, the
  # one that mattered would be whichever this module happened to be given.
  network_policy_enforced = local.network_policy_enforced

  labels = {
    "eaf.io/layer" = "apps"
  }
}

# ── Firecrawl ─────────────────────────────────────────────────────────────────
#
# COUNT-GATED ON THE IMAGE TAG, which is Property 6 made structural: with no tag there is no
# deployment, so the layer cannot reference an image that has not been pushed.
#
# Sized to fit rather than to upstream's defaults. Their Helm chart asks for roughly 10,250m
# CPU and ~26.5 GB — against two m6i.large offering about 3,860m and 14.3 GiB with Neo4j
# already resident. `modules/firecrawl` defaults to about 1,450m and 5,184Mi, and enforces that
# with a plan-time budget check rather than trusting the arithmetic in a comment.
#
# The reduction is mostly one number: nuq-worker ships at FIVE replicas requesting 1000m and
# 3G each. Replicas are the right dial to turn when something is actually crawling.
module "firecrawl" {
  source = "../../../modules/firecrawl"
  count  = var.firecrawl_image_tag == null ? 0 : 1

  name      = "firecrawl"
  namespace = var.firecrawl_namespace

  registry  = local.ecr_registry
  image_tag = var.firecrawl_image_tag

  # Read from the layer that created it, not restated.
  storage_class_name = local.storage_class_name

  # Empty until something consumes the API. It is unauthenticated, so this list is the only
  # access control in front of it.
  allowed_client_namespaces = var.firecrawl_client_namespaces

  # The TOOLS namespace's enforcement state, not the memory namespace's.
  network_policy_enforced = local.firecrawl_policy_enforced

  labels = {
    "eaf.io/layer" = "apps"
  }
}
