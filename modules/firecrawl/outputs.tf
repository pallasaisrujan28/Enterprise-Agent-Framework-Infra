output "api_url" {
  description = "In-cluster URL for the Firecrawl API. This is what a consumer puts in `FIRECRAWL_URL`."
  value       = "http://${var.name}-api.${var.namespace}.svc.cluster.local:3002"
}

output "api_service_name" {
  description = "Name of the API Service, read from the resource so anything referencing it waits for the Service to exist."
  value       = kubernetes_service_v1.this["api"].metadata[0].name
}

output "inventory" {
  description = "Structured record of this deployment, for cross-layer inventory and review."
  value = {
    name      = var.name
    namespace = var.namespace
    api_url   = "http://${var.name}-api.${var.namespace}.svc.cluster.local:3002"
    image_tag = var.image_tag

    # ── Capacity, computed rather than restated ────────────────────────────────
    #
    # These are the same values the plan-time budget check uses, so the inventory cannot
    # disagree with what was verified.
    capacity = {
      cpu_millicores_requested = local.total_cpu_m
      cpu_budget               = var.cpu_budget_millicores
      memory_mib_requested     = local.total_mem_mib
      memory_budget            = var.memory_budget_mib

      # For context on how far this was shrunk. Upstream's chart defaults sum to roughly
      # 10,250m and 26.5 GB, which does not fit two m6i.large.
      upstream_default_cpu_millicores = 10250
      pods                            = sum([for k, w in var.workloads : w.replicas])
    }

    per_workload = {
      for k, w in var.workloads : k => {
        replicas    = w.replicas
        cpu         = w.cpu
        memory      = w.memory
        cpu_total_m = local.cpu_m[k]
      }
    }

    # ── The honest access flags ────────────────────────────────────────────────
    access = {
      # False, and not configurable. Firecrawl's self-hosted default has no API
      # authentication and cannot gain it without the Supabase stack it depends on.
      api_authentication_enabled = false

      # Which means this is the ONLY access control in front of an unauthenticated scraping
      # API, rather than a second layer behind a key.
      policy_enforced       = var.network_policy_enforced
      reachable_by          = sort(var.allowed_client_namespaces)
      reachable_by_anything = local.create_policy

      service_type          = "ClusterIP"
      internet_reachable    = false
      creates_load_balancer = false
    }

    # ── Capability limits, recorded rather than discovered later ───────────────
    capabilities = {
      supported = ["scrape", "crawl", "map", "search"]

      # Both need Fire Engine, which is not part of the self-hosted distribution.
      unsupported = ["screenshots", "page actions"]

      # Verified in apps/api/src/search/index.ts: the fallback chain is
      # FIRE_ENGINE_BETA_URL -> SEARXNG_ENDPOINT -> DuckDuckGo, and a configured SearXNG still
      # falls through when it returns nothing. Neither is set here.
      search_backend = "duckduckgo"

      # Worth stating: DuckDuckGo is scraped, from a single NAT egress IP. Search is the least
      # reliable route under load, and unlike the others its failure mode is empty results
      # rather than an error.
      search_is_rate_limit_prone = true
    }

    storage = {
      class_name = var.storage_class_name
      size       = var.postgres_storage_size

      # The queue holds in-flight jobs, not crawl output, so losing it loses queued work and
      # nothing durable.
      data_is_destroyed_with_this_module = true
      holds_durable_data                 = false
    }
  }
}
