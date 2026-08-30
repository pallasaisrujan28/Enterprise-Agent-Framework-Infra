# Langfuse self-hosted — LLM observability for the agent.
#
# Data residency: all trace data stays inside EKS in eu-west-2.
# No data leaves the cluster to any external SaaS service.
#
# Chart 2.x architecture (all bundled in Kubernetes):
#   langfuse-web     — UI + API server (docker.langfuse.com)
#   langfuse-worker  — async trace processor (docker.langfuse.com)
#   PostgreSQL       — groundhog2k/postgres (docker.io/postgres:18)
#   ClickHouse       — operator with clickhouse-server:26.4
#   Valkey/Redis     — valkey-io/valkey (docker.io/valkey/valkey:8.0)
#   SeaweedFS        — chrislusf/seaweedfs:3.95 (replaces MinIO)
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

resource "random_password" "langfuse_redis_password" {
  length  = 32
  special = false
}

resource "random_password" "langfuse_clickhouse_password" {
  length  = 32
  special = false
}

# ── Kubernetes secret for Langfuse credentials ────────────────────────────────
# All sensitive values in one secret. Chart 2.x supports secretKeyRef for
# salt, nextauth.secret, and existingSecret for PostgreSQL/Redis/ClickHouse.

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
    salt                = random_password.langfuse_salt.result
    nextauth-secret     = random_password.langfuse_nextauth_secret.result
    postgres-password   = random_password.langfuse_postgres_password.result
    password            = random_password.langfuse_postgres_password.result
    redis-password      = random_password.langfuse_redis_password.result
    clickhouse-password = random_password.langfuse_clickhouse_password.result
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
  version          = "2.0.2"
  namespace        = kubernetes_namespace.langfuse.metadata[0].name
  create_namespace = false
  wait             = false # pods start async; health checked separately

  values = [
    yamlencode({
      langfuse = {
        # salt and nextauth.secret use secretKeyRef format (chart 2.x)
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
        # encryptionKey: leave empty — chart auto-generates and persists in <release>-app secret
        tolerations = [
          { key = "dedicated", value = "langfuse", effect = "NoSchedule", operator = "Equal" }
        ]
        nodeSelector = { dedicated = "langfuse" }
        # allowV1Upgrade: true required when upgrading from chart 1.x (bitnami-based stores)
        allowV1Upgrade = true
      }

      # PostgreSQL — groundhog2k/postgres sub-chart (docker.io/postgres:18)
      postgresql = {
        deploy = true
        auth = {
          existingSecret = kubernetes_secret.langfuse_credentials.metadata[0].name
          secretKeys = {
            adminPasswordKey = "postgres-password"
            userPasswordKey  = "password"
          }
        }
        tolerations = [
          { key = "dedicated", value = "langfuse", effect = "NoSchedule", operator = "Equal" }
        ]
        nodeSelector = { dedicated = "langfuse" }
      }

      # Redis/Valkey — valkey-io/valkey sub-chart (docker.io/valkey/valkey:8.0)
      redis = {
        deploy = true
        auth = {
          existingSecret            = kubernetes_secret.langfuse_credentials.metadata[0].name
          existingSecretPasswordKey = "redis-password"
        }
      }

      # ClickHouse — via altinity operator (clickhouse-server:26.4)
      # keeper.replicas=1 for dev (production uses 3 for HA)
      clickhouse = {
        deploy = true
        auth = {
          existingSecret    = kubernetes_secret.langfuse_credentials.metadata[0].name
          existingSecretKey = "clickhouse-password"
        }
        cluster = {
          replicas = 1
          resources = {
            requests = { cpu = "500m", memory = "2Gi" }
            limits   = { memory = "4Gi" }
          }
          tolerations = [
            { key = "dedicated", value = "langfuse", effect = "NoSchedule", operator = "Equal" }
          ]
          nodeSelector = { dedicated = "langfuse" }
        }
        keeper = {
          enabled  = true
          replicas = 1
          tolerations = [
            { key = "dedicated", value = "langfuse", effect = "NoSchedule", operator = "Equal" }
          ]
          nodeSelector = { dedicated = "langfuse" }
        }
      }

      # S3/SeaweedFS — chrislusf/seaweedfs:3.95 (replaces MinIO from 1.x)
      s3 = {
        deploy = true
        allInOne = {
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
