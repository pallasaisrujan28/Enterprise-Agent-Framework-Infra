# lab/apps — the services the agent needs.
#
# Reads lab/cluster's local state for the cluster endpoint. Nothing here is in workloads/, and
# nothing here is subject to the design's correctness properties — see lab/GOAL.md.
#
# One resource per KIND, driven by a map. Adding a service is a map entry, not a file.

terraform {
  required_version = "~> 1.13"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = "../cluster/terraform.tfstate"
  }
}

locals {
  cluster_name = data.terraform_remote_state.cluster.outputs.cluster_name
  region       = data.terraform_remote_state.cluster.outputs.region
}

# `exec` rather than a token read at plan time: an apply that takes a few minutes outlives a
# token fetched at the start of it. No --role-arn — the operator's own SSO role is the cluster
# admin, which is the whole reason kubectl works here without a hop.
provider "kubernetes" {
  host                   = data.terraform_remote_state.cluster.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", local.region]
  }
}

resource "kubernetes_namespace_v1" "agent" {
  metadata {
    name = var.namespace
  }
}

# ── The gp3 StorageClass ──────────────────────────────────────────────────────
#
# EKS ships a `gp2` class and marks it default. gp3 is faster at baseline and cheaper
# ($0.0928 vs $0.1160 per GB-month), so this becomes the default instead and gp2 is left alone
# rather than adopted or deleted.
#
# WaitForFirstConsumer, not Immediate. An EBS volume is zonal: bound immediately it is created
# before the scheduler has picked a node, and if that zone has no room the pod is unschedulable
# forever, with a Pending PVC that looks like the cause rather than the symptom.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

# ── Credentials ───────────────────────────────────────────────────────────────
#
# Generated, not chosen. Alphanumeric only: these travel through connection strings and shell
# environments, and Neo4j in particular parses its own credential with `cut -d '/'`, so a
# slash silently truncates the password and authentication then fails against a value nothing
# generated.
resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "neo4j" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "creds" {
  metadata {
    name      = "agent-credentials"
    namespace = kubernetes_namespace_v1.agent.metadata[0].name
  }

  data = {
    POSTGRES_PASSWORD = random_password.postgres.result
    POSTGRES_USER     = "agent"
    POSTGRES_DB       = "agent"

    # The pair, not a bare password. The Neo4j image reads `user/password` from this one
    # variable and rejects anything that does not start with `neo4j/`.
    #
    # AND NOTHING ELSE MAY BE NAMED NEO4J_*. There was a NEO4J_PASSWORD here, and it stopped
    # Neo4j starting:
    #
    #   Failed to read config: Unrecognized setting. No declared setting with name: PASSWORD
    #
    # The entrypoint treats every NEO4J_* variable as a configuration setting, and NEO4J_AUTH
    # is the one exception it special-cases. So a shared secret can carry exactly one
    # NEO4J_-prefixed key. Consumers that want the bare password split NEO4J_AUTH on the slash.
    NEO4J_AUTH = "neo4j/${random_password.neo4j.result}"
  }
}

# ── Volumes for the services that keep state ──────────────────────────────────
#
# Owned here rather than left to a StatefulSet's volumeClaimTemplate. Kubernetes deliberately
# does NOT delete volumeClaimTemplate PVCs when the StatefulSet goes away, so a chart-owned
# claim survives `terraform destroy` and leaves an EBS volume billing with nothing tracking it.
# Owning the claim means destroy actually destroys.
resource "kubernetes_persistent_volume_claim_v1" "data" {
  for_each = { for k, v in var.services : k => v if v.storage != null }

  metadata {
    name      = "${each.key}-data"
    namespace = kubernetes_namespace_v1.agent.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.gp3.metadata[0].name
    resources {
      requests = {
        storage = each.value.storage
      }
    }
  }

  # WaitForFirstConsumer means the volume is not created until a pod needs it — so waiting for
  # the claim to bind here waits for a pod this same apply has not created yet.
  wait_until_bound = false
}

# ── The services ──────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "service" {
  for_each = var.services

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.agent.metadata[0].name
    labels    = { app = each.key }
  }

  spec {
    # One replica each. These are single-writer datastores; a second replica of Postgres or
    # Neo4j on the same ReadWriteOnce volume does not work and is not a scaling story.
    replicas = 1

    selector {
      match_labels = { app = each.key }
    }

    # Recreate, not RollingUpdate. A rolling update would start the new pod before the old one
    # released the volume, and a ReadWriteOnce claim cannot attach twice — so the rollout
    # deadlocks with the new pod stuck ContainerCreating.
    strategy {
      type = each.value.storage == null ? "RollingUpdate" : "Recreate"
    }

    template {
      metadata {
        labels = { app = each.key }
      }

      spec {
        # KUBERNETES INJECTS LEGACY SERVICE-DISCOVERY ENV VARS UNLESS TOLD NOT TO, and for
        # Neo4j that is fatal rather than untidy.
        #
        # Every Service in the namespace contributes variables like NEO4J_PORT_7687_TCP_PORT
        # to every pod. Neo4j's entrypoint treats any NEO4J_* variable as a configuration
        # setting, so it tries to parse `PORT.7687.TCP.PORT` as a Neo4j setting and refuses to
        # start:
        #
        #   Failed to read config: Unrecognized setting. No declared setting with name:
        #   PORT.7687.TCP.PORT
        #
        # The Service name collides with the application's own config prefix. Turning the
        # injection off is the fix; disabling Neo4j's strict validation would only hide it, and
        # renaming the Service would leave the collision waiting for the next app.
        #
        # Nothing here needs these variables — every service is reached by DNS.
        enable_service_links = false

        container {
          name  = each.key
          image = each.value.image
          args  = each.value.args

          dynamic "port" {
            for_each = each.value.ports
            content {
              container_port = port.value
            }
          }

          # Every service sees the whole credential set. Simpler than working out which needs
          # what — but NOT free, which an earlier version of this comment claimed. An app that
          # reads its own env prefix as configuration will choke on a key meant for something
          # else: Neo4j did exactly that with a NEO4J_PASSWORD key intended for consumers.
          # A new key here needs a moment's thought about whose prefix it borrows.
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.creds.metadata[0].name
            }
          }

          dynamic "env" {
            for_each = each.value.env
            content {
              name  = env.key
              value = env.value
            }
          }

          resources {
            requests = {
              cpu    = each.value.cpu
              memory = each.value.memory
            }
            # Memory limit equals the request; no CPU limit. CPU is compressible, so a limit
            # there throttles rather than protects — and a throttled RL loop presents as
            # mysterious slowness rather than as a resource problem.
            limits = {
              memory = each.value.memory
            }
          }

          # TCP, not HTTP: it works for every one of these without knowing each app's health
          # path, and "the port accepts a connection" is the property that actually matters
          # to a client.
          dynamic "readiness_probe" {
            for_each = each.value.ready_port == null ? [] : [each.value.ready_port]
            content {
              tcp_socket {
                port = readiness_probe.value
              }
              initial_delay_seconds = 10
              period_seconds        = 10
              # Neo4j with APOC needs roughly 45s. 30 failures at 10s gives five minutes before
              # Kubernetes gives up, which is generous rather than optimistic.
              failure_threshold = 30
            }
          }

          dynamic "volume_mount" {
            for_each = each.value.storage == null ? [] : [1]
            content {
              name       = "data"
              mount_path = each.value.mount_path
              # A subdirectory, not the mount root. An EBS volume arrives with a lost+found
              # directory, and Postgres refuses to initialise into a non-empty directory.
              sub_path = "data"
            }
          }

        }

        dynamic "volume" {
          for_each = each.value.storage == null ? [] : [1]
          content {
            name = "data"
            persistent_volume_claim {
              claim_name = kubernetes_persistent_volume_claim_v1.data[each.key].metadata[0].name
            }
          }
        }
      }
    }
  }

  timeouts {
    create = "10m"
  }
}

resource "kubernetes_service_v1" "service" {
  for_each = { for k, v in var.services : k => v if length(v.ports) > 0 }

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.agent.metadata[0].name
  }

  spec {
    selector = { app = each.key }

    dynamic "port" {
      for_each = each.value.ports
      content {
        name        = "p${port.value}"
        port        = port.value
        target_port = port.value
      }
    }

    # ClusterIP. A LoadBalancer here would publish an unauthenticated datastore to the
    # internet and create an AWS resource no Terraform state knows about, which then survives
    # a destroy and keeps billing. Reach these with `kubectl port-forward`.
    type = "ClusterIP"
  }
}
