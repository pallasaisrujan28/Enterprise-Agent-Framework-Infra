# SEARCH TOOLS STACK — SearXNG + Firecrawl
#
# Two components that give the agent web access:
#
#   SearXNG     → web search (aggregates Google, Bing, DuckDuckGo, etc.)
#                 Internal URL: http://searxng.tools.svc.cluster.local:8080
#
#   Firecrawl   → full site crawl + single URL → clean markdown
#                 Handles complex JS, async job queue, link-following.
#                 Internal URL: http://firecrawl-api.tools.svc.cluster.local:3002
#                 Stack: api + worker + playwright + redis
#
# Memory (Graphiti / Neo4j) lives in memory.tf — separate concern.
# Images are scanned by Trivy in the deploy pipeline before apply.

locals {
  ecr = "${var.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

resource "random_password" "searxng_secret" {
  length  = 32
  special = false
}

resource "random_password" "firecrawl_api_key" {
  length  = 32
  special = false
}

# ── Namespace ──────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "tools" {
  metadata {
    name = "tools"
    labels = {
      purpose   = "agent-tool-backends"
      ManagedBy = "terraform"
    }
  }
  depends_on = [aws_eks_node_group.default, aws_eks_access_policy_association.org_role_admin]
}

# ── SearXNG ────────────────────────────────────────────────────────────────────

resource "kubernetes_config_map" "searxng" {
  metadata {
    name      = "searxng-config"
    namespace = kubernetes_namespace.tools.metadata[0].name
  }

  data = {
    "settings.yml" = yamlencode({
      general = {
        instance_name = "EAF Search"
        debug         = false
      }
      server = {
        secret_key   = random_password.searxng_secret.result
        bind_address = "0.0.0.0"
        port         = 8080
      }
      search = {
        safe_search = 0
        formats     = ["html", "json"]
      }
      engines = [
        { name = "google", engine = "google", shortcut = "g" },
        { name = "bing", engine = "bing", shortcut = "b" },
        { name = "duckduckgo", engine = "duckduckgo", shortcut = "ddg" },
        { name = "wikipedia", engine = "wikipedia", shortcut = "wp" },
        { name = "arxiv", engine = "arxiv", shortcut = "ar" },
      ]
    })
  }
}

resource "kubernetes_deployment" "searxng" {
  wait_for_rollout = false
  metadata {
    name      = "searxng"
    namespace = kubernetes_namespace.tools.metadata[0].name
    labels    = { app = "searxng" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "searxng" } }
    template {
      metadata { labels = { app = "searxng" } }
      spec {
        container {
          name  = "searxng"
          image = "${local.ecr}/tools/searxng:latest"
          port { container_port = 8080 }
          env {
            name  = "SEARXNG_SETTINGS_PATH"
            value = "/etc/searxng/settings.yml"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/searxng"
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }
        volume {
          name = "config"
          config_map { name = kubernetes_config_map.searxng.metadata[0].name }
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.tools]
}

resource "kubernetes_service" "searxng" {
  metadata {
    name      = "searxng"
    namespace = kubernetes_namespace.tools.metadata[0].name
  }
  spec {
    selector = { app = "searxng" }
    port {
      port        = 8080
      target_port = 8080
    }
    type = "ClusterIP"
  }
}

# ── Firecrawl ──────────────────────────────────────────────────────────────────
# Four-component stack: redis → playwright → api → worker
#
# API endpoint:  http://firecrawl-api.tools.svc.cluster.local:3002
# Scrape:        POST /v1/scrape    { url, formats: ["markdown"] }
# Crawl site:    POST /v1/crawl     { url, limit, formats: ["markdown"] }
# Auth:          Authorization: Bearer <firecrawl_api_key>

resource "kubernetes_deployment" "firecrawl_redis" {
  wait_for_rollout = false
  metadata {
    name      = "firecrawl-redis"
    namespace = kubernetes_namespace.tools.metadata[0].name
    labels    = { app = "firecrawl-redis" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "firecrawl-redis" } }
    template {
      metadata { labels = { app = "firecrawl-redis" } }
      spec {
        container {
          name  = "redis"
          image = "redis:7-alpine"
          port { container_port = 6379 }
          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.tools]
}

resource "kubernetes_service" "firecrawl_redis" {
  metadata {
    name      = "firecrawl-redis"
    namespace = kubernetes_namespace.tools.metadata[0].name
  }
  spec {
    selector = { app = "firecrawl-redis" }
    port {
      port        = 6379
      target_port = 6379
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_deployment" "firecrawl_playwright" {
  wait_for_rollout = false
  metadata {
    name      = "firecrawl-playwright"
    namespace = kubernetes_namespace.tools.metadata[0].name
    labels    = { app = "firecrawl-playwright" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "firecrawl-playwright" } }
    template {
      metadata { labels = { app = "firecrawl-playwright" } }
      spec {
        container {
          name  = "playwright"
          image = "${local.ecr}/tools/firecrawl-playwright:latest"
          port { container_port = 3000 }
          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "1", memory = "2Gi" }
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 3000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.tools]
}

resource "kubernetes_service" "firecrawl_playwright" {
  metadata {
    name      = "firecrawl-playwright"
    namespace = kubernetes_namespace.tools.metadata[0].name
  }
  spec {
    selector = { app = "firecrawl-playwright" }
    port {
      port        = 3000
      target_port = 3000
    }
    type = "ClusterIP"
  }
}

locals {
  firecrawl_env = [
    { name = "REDIS_URL", value = "redis://firecrawl-redis.tools.svc.cluster.local:6379" },
    { name = "REDIS_RATE_LIMIT_URL", value = "redis://firecrawl-redis.tools.svc.cluster.local:6379" },
    { name = "PLAYWRIGHT_MICROSERVICE_URL", value = "http://firecrawl-playwright.tools.svc.cluster.local:3000" },
    { name = "FIRECRAWL_API_KEY", value = random_password.firecrawl_api_key.result },
    { name = "USE_DB_AUTHENTICATION", value = "false" },
    { name = "PORT", value = "3002" },
    { name = "HOST", value = "0.0.0.0" },
  ]
}

resource "kubernetes_deployment" "firecrawl_api" {
  wait_for_rollout = false
  metadata {
    name      = "firecrawl-api"
    namespace = kubernetes_namespace.tools.metadata[0].name
    labels    = { app = "firecrawl-api" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "firecrawl-api" } }
    template {
      metadata { labels = { app = "firecrawl-api" } }
      spec {
        dynamic "container" {
          for_each = [1]
          content {
            name    = "api"
            image   = "${local.ecr}/tools/firecrawl:latest"
            command = ["pnpm", "run", "start:production"]
            port { container_port = 3002 }
            dynamic "env" {
              for_each = local.firecrawl_env
              content {
                name  = env.value.name
                value = env.value.value
              }
            }
            resources {
              requests = { cpu = "250m", memory = "512Mi" }
              limits   = { cpu = "1", memory = "1Gi" }
            }
            liveness_probe {
              http_get {
                path = "/health"
                port = 3002
              }
              initial_delay_seconds = 60
              period_seconds        = 30
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_deployment.firecrawl_redis,
    kubernetes_deployment.firecrawl_playwright,
  ]
}

resource "kubernetes_service" "firecrawl_api" {
  metadata {
    name      = "firecrawl-api"
    namespace = kubernetes_namespace.tools.metadata[0].name
  }
  spec {
    selector = { app = "firecrawl-api" }
    port {
      port        = 3002
      target_port = 3002
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_deployment" "firecrawl_worker" {
  wait_for_rollout = false
  metadata {
    name      = "firecrawl-worker"
    namespace = kubernetes_namespace.tools.metadata[0].name
    labels    = { app = "firecrawl-worker" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "firecrawl-worker" } }
    template {
      metadata { labels = { app = "firecrawl-worker" } }
      spec {
        dynamic "container" {
          for_each = [1]
          content {
            name    = "worker"
            image   = "${local.ecr}/tools/firecrawl:latest"
            command = ["pnpm", "run", "workers"]
            dynamic "env" {
              for_each = local.firecrawl_env
              content {
                name  = env.value.name
                value = env.value.value
              }
            }
            resources {
              requests = { cpu = "250m", memory = "512Mi" }
              limits   = { cpu = "1", memory = "1Gi" }
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_deployment.firecrawl_redis,
    kubernetes_deployment.firecrawl_playwright,
    kubernetes_deployment.firecrawl_api,
  ]
}
