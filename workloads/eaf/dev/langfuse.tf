# Langfuse self-hosted — LLM observability for the agent.
#
# Data residency: all trace data stays inside EKS in eu-west-2.
# No data leaves the cluster to any external SaaS service.
#
# Architecture (all bundled in Kubernetes):
#   langfuse-web     — UI + API server
#   langfuse-worker  — async trace processor
#   PostgreSQL       — user data, config, prompts
#   ClickHouse       — traces, observations, scores (analytics)
#   Redis/Valkey     — queue and cache
#   SeaweedFS        — blob storage for raw events and attachments
#
# All Langfuse pods run on the dedicated langfuse node group (t3.large)
# via tolerations, keeping them isolated from agent workloads.
#
# Helm installation order (enforced via depends_on):
#   1. cert-manager       — TLS between components
#   2. ClickHouse operator — CRDs required before ClickHouse pods start
#   3. Langfuse           — the actual observability stack

# ── Random secrets ────────────────────────────────────────────────────────────

resource "random_password" "langfuse_salt" {
  length  = 32
  special = false
}

resource "random_password" "langfuse_nextauth_secret" {
  length  = 32
  special = false
}

resource "random_password" "langfuse_postgres_password" {
  length  = 32
  special = false
}

# ── Kubernetes secret for Langfuse credentials ────────────────────────────────
# Langfuse chart 1.2.x uses getValueOrSecret helper which expects either
# a plain string or { secretKeyRef: { name, key } }. We use secretKeyRef
# to pass sensitive values properly through the chart's template engine.

resource "kubernetes_namespace" "langfuse" {
  metadata {
    name = "langfuse"
  }
  depends_on = [aws_eks_node_group.langfuse]
}

resource "kubernetes_secret" "langfuse_credentials" {
  metadata {
    name      = "langfuse-credentials"
    namespace = kubernetes_namespace.langfuse.metadata[0].name
  }

  data = {
    salt              = random_password.langfuse_salt.result
    nextauth-secret   = random_password.langfuse_nextauth_secret.result
    postgres-password = random_password.langfuse_postgres_password.result
    password          = random_password.langfuse_postgres_password.result
  }
}



# ── Step 1: cert-manager ───────────────────────────────────────────────────────

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.16.0"
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "crds.enabled"
    value = "true"
  }

  depends_on = [aws_eks_node_group.langfuse, aws_eks_access_policy_association.org_role_admin]
}

# ── Step 2: ClickHouse Kubernetes Operator ─────────────────────────────────────

resource "helm_release" "clickhouse_operator" {
  name             = "clickhouse-operator"
  repository       = "https://docs.altinity.com/clickhouse-operator"
  chart            = "altinity-clickhouse-operator"
  namespace        = "kube-system"
  create_namespace = false
  wait             = true
  timeout          = 300

  depends_on = [helm_release.cert_manager]
}

# ── Step 3: Langfuse ───────────────────────────────────────────────────────────

resource "helm_release" "langfuse" {
  name             = "langfuse"
  repository       = "https://langfuse.github.io/langfuse-k8s"
  chart            = "langfuse"
  version          = "1.2.4"
  namespace        = kubernetes_namespace.langfuse.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600 # ClickHouse takes a while to start

  values = [
    yamlencode({
      langfuse = {
        # secretKeyRef format — required by chart 1.2.x getValueOrSecret helper
        salt = {
          secretKeyRef = {
            name = kubernetes_secret.langfuse_credentials.metadata[0].name
            key  = "salt"
          }
        }
        nextauth = {
          secret = {
            secretKeyRef = {
              name = kubernetes_secret.langfuse_credentials.metadata[0].name
              key  = "nextauth-secret"
            }
          }
          url = "http://langfuse-web.langfuse.svc.cluster.local:3000"
        }
        additionalEnv = [
          { name = "AUTH_DISABLE_USERNAME_PASSWORD", value = "false" }
        ]
      }

      tolerations = [
        { key = "dedicated", value = "langfuse", effect = "NoSchedule", operator = "Equal" }
      ]
      nodeSelector = { dedicated = "langfuse" }

      postgresql = {
        deploy = true
        auth = {
          existingSecret = kubernetes_secret.langfuse_credentials.metadata[0].name
          secretKeys = {
            adminPasswordKey = "postgres-password"
            userPasswordKey  = "password"
          }
        }
        primary = {
          tolerations = [
            { key = "dedicated", value = "langfuse", effect = "NoSchedule", operator = "Equal" }
          ]
          nodeSelector = { dedicated = "langfuse" }
        }
      }

      redis = {
        deploy = true
        master = {
          tolerations = [
            { key = "dedicated", value = "langfuse", effect = "NoSchedule", operator = "Equal" }
          ]
          nodeSelector = { dedicated = "langfuse" }
        }
      }

      clickhouse = {
        deploy   = true
        shards   = 1
        replicas = 1
      }

      seaweedfs = {
        deploy = true
        master = {
          tolerations = [
            { key = "dedicated", value = "langfuse", effect = "NoSchedule", operator = "Equal" }
          ]
          nodeSelector = { dedicated = "langfuse" }
        }
      }
    })
  ]

  depends_on = [helm_release.clickhouse_operator, kubernetes_secret.langfuse_credentials]
}
