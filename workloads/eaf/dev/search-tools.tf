# SEARCH TOOLS STACK — SearXNG + Crawl4AI + Qdrant
#
# Three components that back the agent's semantic tool registry:
#
#   SearXNG     → web search (aggregates Google, Bing, DuckDuckGo, etc.)
#                 Internal endpoint: http://searxng.tools.svc.cluster.local:8080
#
#   Crawl4AI    → URL to clean markdown, semantic chunking, link following
#                 Internal endpoint: http://crawl4ai.tools.svc.cluster.local:11235
#
#   Qdrant      → vector store for session working memory
#                 (stores retrieved web content across multi-hop reasoning)
#                 Internal endpoint: http://qdrant.tools.svc.cluster.local:6333
#
# None of these are wired directly as agent tools. They are the BACKENDS
# for three semantically discoverable tools in the ToolRegistry:
#   web_search       → SearXNG
#   fetch_and_store  → Crawl4AI + Qdrant
#   search_memory    → Qdrant

resource "random_password" "searxng_secret" {
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
  depends_on = [aws_eks_node_group.default]
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
        # JSON format MUST be enabled for the agent to call the API.
        formats = ["html", "json"]
      }
      # Engines the agent will query. Kept minimal — all free, no API keys.
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
          image = "searxng/searxng:latest"

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

# ── Crawl4AI ───────────────────────────────────────────────────────────────────
# Runs Crawl4AI in server mode (FastAPI on port 11235).
# The agent calls it to convert URLs → clean markdown, chunk semantically,
# and follow links. Playwright is pre-installed for JS-rendered pages.

resource "kubernetes_deployment" "crawl4ai" {
  metadata {
    name      = "crawl4ai"
    namespace = kubernetes_namespace.tools.metadata[0].name
    labels    = { app = "crawl4ai" }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "crawl4ai" } }

    template {
      metadata { labels = { app = "crawl4ai" } }
      spec {
        container {
          name  = "crawl4ai"
          image = "unclecode/crawl4ai:latest"

          port { container_port = 11235 }

          env {
            name  = "CRAWL4AI_API_TOKEN"
            value = "internal"
          }

          resources {
            # Playwright (Chromium) needs reasonable memory
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "1", memory = "2Gi" }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 11235
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.tools]
}

resource "kubernetes_service" "crawl4ai" {
  metadata {
    name      = "crawl4ai"
    namespace = kubernetes_namespace.tools.metadata[0].name
  }
  spec {
    selector = { app = "crawl4ai" }
    port {
      port        = 11235
      target_port = 11235
    }
    type = "ClusterIP"
  }
}

# ── Qdrant ─────────────────────────────────────────────────────────────────────
# Vector store for the agent's session working memory.
# Stores semantic chunks of retrieved web content across multi-hop reasoning.
# The agent queries it to find relevant content without re-fetching URLs.

resource "helm_release" "qdrant" {
  name             = "qdrant"
  repository       = "https://qdrant.github.io/qdrant-helm"
  chart            = "qdrant"
  namespace        = kubernetes_namespace.tools.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 300

  set {
    name  = "persistence.enabled"
    value = "true"
  }
  set {
    name  = "persistence.size"
    value = "5Gi"
  }
  set {
    name  = "resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "resources.limits.memory"
    value = "1Gi"
  }

  depends_on = [kubernetes_namespace.tools]
}
