# Firecrawl, self-hosted, sized to fit this cluster.
#
# ONE `kubernetes_deployment_v1` FOR ALL EIGHT WORKLOADS, driven by a map.
#
# They differ only in image, command, port and size, so eight near-identical resource blocks
# would be eight places to forget the same fix. `for_each` over a map is also module
# convention 5 — keyed by name, so adding or removing a workload does not shift anyone else's
# resource address the way a list index would.
#
# WHAT UPSTREAM DOES THAT THIS DOES NOT.
#
# Their compose runs the API as `node dist/src/harness.js --start-docker`, which spawns the
# workers inside the API container. That flag is docker-specific, so the Kubernetes topology
# splits them — which is what their own Helm chart does, and what this follows.
#
# FoundationDB is absent on purpose. Upstream's compose includes it as two services, reached
# only when NUQ_BACKEND is set: the compose expands ${NUQ_BACKEND:+/var/fdb/fdb.cluster}, so
# with the variable unset the queue uses Postgres and FoundationDB is never contacted. Leaving
# it out costs nothing and saves operating a distributed key-value store.
#
# SEARCH NEEDS NO KEY AND NO SEARXNG. Verified in apps/api/src/search/index.ts: the provider
# falls back FIRE_ENGINE_BETA_URL -> SEARXNG_ENDPOINT -> DuckDuckGo, and even a configured
# SearXNG falls through when it returns nothing. With neither set, /search works via
# DuckDuckGo. Worth knowing that DuckDuckGo is being scraped from a single NAT egress IP, so
# search is the least reliable of the routes under load.

locals {
  # Three EAF-owned images, all at the same commit. Redis and RabbitMQ are stock upstream and
  # carry no EAF layer, so they are referenced directly and pinned by tag rather than SHA —
  # they are not built here and have no commit to name.
  images = {
    api        = "${var.registry}/tools/firecrawl:${var.image_tag}"
    playwright = "${var.registry}/tools/firecrawl-playwright:${var.image_tag}"
    postgres   = "${var.registry}/tools/firecrawl-nuq-postgres:${var.image_tag}"
    redis      = "redis:8.2-alpine"
    rabbitmq   = "rabbitmq:4.1-management-alpine"
  }

  # Workloads that other workloads reach by DNS need a Service.
  serviced = { for k, w in var.workloads : k => w if w.port != null }

  common_labels = merge(var.labels, {
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = var.name
    "eaf.io/module"                = "firecrawl"
  })

  # ── The capacity arithmetic, done here rather than trusted ──────────────────
  #
  # Requests are strings with unit suffixes, so they have to be parsed before they can be
  # summed. Only the two forms this module's own variables use are handled; anything else
  # yields zero, which would understate the total — so the preconditions below also assert
  # every value parsed to something non-zero.
  cpu_m = {
    for k, w in var.workloads : k => (
      endswith(w.cpu, "m") ? tonumber(trimsuffix(w.cpu, "m")) : tonumber(w.cpu) * 1000
    ) * w.replicas
  }

  mem_mib = {
    for k, w in var.workloads : k => (
      endswith(w.memory, "Gi") ? tonumber(trimsuffix(w.memory, "Gi")) * 1024 :
      endswith(w.memory, "Mi") ? tonumber(trimsuffix(w.memory, "Mi")) : 0
    ) * w.replicas
  }

  total_cpu_m   = sum(values(local.cpu_m))
  total_mem_mib = sum(values(local.mem_mib))

  create_policy = var.network_policy_enforced && length(var.allowed_client_namespaces) > 0
}

# ── Property 9, enforced at plan time ─────────────────────────────────────────
#
# A `check` rather than a resource precondition, so it reports on every plan of the layer
# rather than only when something about a particular resource changes.
check "requests_fit_the_declared_budget" {
  assert {
    condition = local.total_cpu_m <= var.cpu_budget_millicores
    error_message = join(" ", [
      "Firecrawl requests ${local.total_cpu_m}m CPU, over the ${var.cpu_budget_millicores}m budget.",
      "This cluster has roughly 2,680m free after kube-system and Neo4j, so raising the budget",
      "is not the fix unless the node group grew. Lower a replica count — nuq-worker is the",
      "one upstream ships at five.",
    ])
  }

  assert {
    condition     = local.total_mem_mib <= var.memory_budget_mib
    error_message = "Firecrawl requests ${local.total_mem_mib}Mi memory, over the ${var.memory_budget_mib}Mi budget. Roughly 11,440Mi is free on this cluster."
  }

  # A request whose units this module cannot parse sums as zero, which would make the two
  # assertions above pass by undercounting. Property 9 checked against a wrong total is worse
  # than not checked, so a zero is a failure rather than a pass.
  assert {
    condition     = alltrue([for k, v in local.cpu_m : v > 0])
    error_message = "a workload's cpu request parsed to zero — use `500m` or `2`, since anything else is silently ignored and would undercount the budget check."
  }

  assert {
    condition     = alltrue([for k, v in local.mem_mib : v > 0])
    error_message = "a workload's memory request parsed to zero — use `512Mi` or `2Gi`. Note `2G` is NOT accepted here: upstream's chart uses it, it is a different unit from `Gi`, and accepting both silently would make the budget wrong."
  }
}

# ── Configuration ─────────────────────────────────────────────────────────────

resource "kubernetes_config_map_v1" "env" {
  metadata {
    name      = "${var.name}-env"
    namespace = var.namespace
    labels    = local.common_labels
  }

  data = {
    # In-cluster addresses. Every one is a Service this module creates, so a rename here and a
    # rename there cannot drift apart.
    REDIS_URL                   = "redis://${var.name}-redis:6379"
    REDIS_RATE_LIMIT_URL        = "redis://${var.name}-redis:6379"
    PLAYWRIGHT_MICROSERVICE_URL = "http://${var.name}-playwright:3000/scrape"
    NUQ_RABBITMQ_URL            = "amqp://${var.name}-rabbitmq:5672"

    POSTGRES_HOST = "${var.name}-nuq-postgres"
    POSTGRES_PORT = "5432"
    POSTGRES_DB   = "postgres"
    POSTGRES_USER = "postgres"

    HOST = "0.0.0.0"
    PORT = "3002"

    # Authentication is off, which is the upstream self-hosted default and cannot be turned on
    # without the Supabase stack it depends on. The NetworkPolicy is the control instead — see
    # the `allowed_client_namespaces` description.
    USE_DB_AUTHENTICATION = "false"

    # Concurrency, lowered with the replica counts. Leaving upstream's values while running one
    # worker instead of five would queue work the cluster cannot process.
    NUM_WORKERS_PER_QUEUE     = "4"
    CRAWL_CONCURRENT_REQUESTS = "5"
    MAX_CONCURRENT_JOBS       = "3"
    BROWSER_POOL_SIZE         = "2"
    MAX_CONCURRENT_PAGES      = "5"

    LOGGING_LEVEL = "info"

    # NUQ_BACKEND deliberately unset — see the header note on FoundationDB.
    # SEARXNG_ENDPOINT deliberately unset — search falls back to DuckDuckGo.
  }
}

# The queue database password. Generated rather than left at upstream's `postgres`/`postgres`,
# which their own documentation flags as local-development only.
resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "env" {
  metadata {
    name      = "${var.name}-secrets"
    namespace = var.namespace
    labels    = local.common_labels
  }

  data = {
    POSTGRES_PASSWORD = random_password.postgres.result
  }

  type = "Opaque"
}

# ── The queue's volume ────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "postgres" {
  metadata {
    name      = "${var.name}-nuq-postgres"
    namespace = var.namespace
    labels    = local.common_labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class_name

    resources {
      requests = {
        storage = var.postgres_storage_size
      }
    }
  }

  # The gp3 class binds WaitForFirstConsumer, so without this the apply blocks waiting for a
  # volume that will not be created until a pod schedules — which is this module's own pod.
  wait_until_bound = false
}

# ── The workloads ─────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "this" {
  for_each = var.workloads

  metadata {
    name      = "${var.name}-${each.key}"
    namespace = var.namespace
    labels = merge(local.common_labels, {
      "app.kubernetes.io/component" = each.key
    })
  }

  spec {
    replicas = each.value.replicas

    selector {
      match_labels = {
        "app.kubernetes.io/part-of"   = var.name
        "app.kubernetes.io/component" = each.key
      }
    }

    template {
      metadata {
        labels = merge(local.common_labels, {
          "app.kubernetes.io/component" = each.key
        })
      }

      spec {
        container {
          name  = each.key
          image = local.images[each.value.image]

          # `command` overrides the image entrypoint, which is how one image serves the API and
          # four different workers.
          command = each.value.command == null ? null : each.value.command

          dynamic "port" {
            for_each = each.value.port == null ? [] : [each.value.port]
            content {
              container_port = port.value
            }
          }

          # Every workload gets the full environment. Simpler than working out which worker
          # reads which variable, and a worker that silently lacks one is harder to diagnose
          # than a container carrying a few it ignores.
          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.env.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.env.metadata[0].name
            }
          }

          # Postgres reads its superuser password from a different variable name than the API
          # reads it from, so the image gets it under the name it expects.
          dynamic "env" {
            for_each = each.value.image == "postgres" ? [1] : []
            content {
              name = "POSTGRES_PASSWORD"
              value_from {
                secret_key_ref {
                  name = kubernetes_secret_v1.env.metadata[0].name
                  key  = "POSTGRES_PASSWORD"
                }
              }
            }
          }

          resources {
            requests = {
              cpu    = each.value.cpu
              memory = each.value.memory
            }
            # Memory limit equals the request: these are the numbers the budget check was run
            # against, and a limit above the request lets a pod exceed what was verified to
            # fit. No CPU limit — CPU is compressible, and a limit there causes throttling
            # rather than protection.
            limits = {
              memory = each.value.memory
            }
          }

          dynamic "volume_mount" {
            for_each = each.value.image == "postgres" ? [1] : []
            content {
              name       = "data"
              mount_path = "/var/lib/postgresql/data"
              sub_path   = "pgdata"
            }
          }
        }

        dynamic "volume" {
          for_each = each.value.image == "postgres" ? [1] : []
          content {
            name = "data"
            persistent_volume_claim {
              claim_name = kubernetes_persistent_volume_claim_v1.postgres.metadata[0].name
            }
          }
        }
      }
    }
  }
}

# ── Service discovery ─────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "this" {
  for_each = local.serviced

  metadata {
    name      = "${var.name}-${each.key}"
    namespace = var.namespace
    labels = merge(local.common_labels, {
      "app.kubernetes.io/component" = each.key
    })
  }

  spec {
    selector = {
      "app.kubernetes.io/part-of"   = var.name
      "app.kubernetes.io/component" = each.key
    }

    port {
      port        = each.value.port
      target_port = each.value.port
    }

    # ClusterIP, never LoadBalancer. The API has no authentication, so a load balancer would
    # publish an unauthenticated scraping service — and it would also be an AWS resource no
    # Terraform state knows about, leaking on teardown. Both failures documented in
    # learnings/007.
    type = "ClusterIP"
  }
}

# ── Who may reach the API ─────────────────────────────────────────────────────
#
# The namespace already denies all ingress, so this is what lets anything in. It admits only
# the API's port from named namespaces: the workers, Redis, RabbitMQ and Postgres talk to each
# other inside the namespace and are not opened to anyone outside it.
resource "kubernetes_network_policy_v1" "allow_api" {
  count = local.create_policy ? 1 : 0

  metadata {
    name      = "${var.name}-allow-api"
    namespace = var.namespace
    labels    = local.common_labels
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/part-of"   = var.name
        "app.kubernetes.io/component" = "api"
      }
    }

    ingress {
      dynamic "from" {
        for_each = toset(var.allowed_client_namespaces)
        content {
          namespace_selector {
            match_labels = {
              "eaf.io/namespace" = from.value
            }
          }
        }
      }

      ports {
        port     = "3002"
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }
}

# Firecrawl's components must reach each other, and the namespace default-denies ingress. A
# separate policy for intra-namespace traffic rather than widening the one above: that one is
# about who may use the API, this one is about the stack functioning at all, and merging them
# would mean a change to either risking the other.
resource "kubernetes_network_policy_v1" "allow_internal" {
  count = var.network_policy_enforced ? 1 : 0

  metadata {
    name      = "${var.name}-allow-internal"
    namespace = var.namespace
    labels    = local.common_labels
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/part-of" = var.name
      }
    }

    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/part-of" = var.name
          }
        }
      }
    }

    policy_types = ["Ingress"]
  }
}
