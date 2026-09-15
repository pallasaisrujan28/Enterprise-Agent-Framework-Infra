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
    # Here for one reason: a pod that calls Bedrock needs an IAM role, and a Pod Identity
    # association is an EKS API call rather than a Kubernetes object.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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
provider "aws" {
  region = local.region
}

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

# ── Bedrock access, via Pod Identity ──────────────────────────────────────────
#
# POD IDENTITY, NOT THE NODE ROLE. This is the same trap the EBS CSI driver fell into: the
# node group sets HttpPutResponseHopLimit = 1, so IMDS answers the node but not a pod one hop
# further on. A pod relying on the node's instance profile gets
#
#   no EC2 IMDS role found, ec2imds: GetMetadata, context deadline exceeded
#
# and the failure takes twenty minutes of CrashLoopBackOff to read. `aws-node` escapes it only
# because it runs with hostNetwork: true. Pod Identity injects credentials over a local
# endpoint instead of IMDS, so the hop limit is irrelevant.
data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# foundation-model ARNs only, deliberately. The organisation's SCP explicitly denies
# inference-profile ARNs, so granting them here would produce a role whose permissions read as
# working and whose calls fail — the least useful combination. What this role can do is what
# the account can actually do.
data "aws_iam_policy_document" "bedrock_invoke" {
  statement {
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["arn:aws:bedrock:*::foundation-model/*"]
  }
}

resource "aws_iam_role" "bedrock" {
  name               = "eaf-lab-bedrock"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy" "bedrock" {
  name   = "bedrock-invoke"
  role   = aws_iam_role.bedrock.id
  policy = data.aws_iam_policy_document.bedrock_invoke.json
}

# Only the pods that call AWS get this. The datastores keep the default ServiceAccount and no
# association, so nothing hands Bedrock to Postgres.
resource "kubernetes_service_account_v1" "bedrock" {
  metadata {
    name      = "agent-bedrock"
    namespace = kubernetes_namespace_v1.agent.metadata[0].name
  }
}

resource "aws_eks_pod_identity_association" "bedrock" {
  cluster_name    = local.cluster_name
  namespace       = kubernetes_namespace_v1.agent.metadata[0].name
  service_account = kubernetes_service_account_v1.bedrock.metadata[0].name
  role_arn        = aws_iam_role.bedrock.arn
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

# LiteLLM's master key, which is also the API key every client presents to it. One value for
# both halves because the proxy is reachable only inside the namespace.
resource "random_password" "litellm" {
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

    # The proxy reads this as its master key; clients send it as their bearer token.
    LITELLM_MASTER_KEY = random_password.litellm.result

    # Graphiti and anything else built on an OpenAI client read these two names by convention,
    # so pointing them at the proxy means no client needs to be told about Bedrock at all.
    # Safe to add to the shared secret: neither borrows a prefix any of these images parses as
    # its own configuration, which is the mistake NEO4J_PASSWORD made.
    OPENAI_API_KEY  = random_password.litellm.result
    OPENAI_BASE_URL = "http://litellm:4000/v1"
  }
}

# ── Config files ──────────────────────────────────────────────────────────────
#
# One ConfigMap per service that declares a config file. Only LiteLLM does today.
resource "kubernetes_config_map_v1" "config" {
  for_each = { for k, v in var.services : k => v if v.config != null }

  metadata {
    name      = "${each.key}-config"
    namespace = kubernetes_namespace_v1.agent.metadata[0].name
  }

  data = {
    (each.value.config.filename) = each.value.config.content
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

        # A ConfigMap change does not restart the pods that mount it — the same way a Secret
        # change does not, which cost a `kubectl rollout restart` to work out last time. Putting
        # the content hash in the pod template makes the template itself change, so editing the
        # LiteLLM config rolls the proxy instead of quietly leaving it on the old one.
        annotations = each.value.config == null ? {} : {
          "eaf.local/config-hash" = sha1(each.value.config.content)
        }
      }

      spec {
        # Null for the datastores, which then get the namespace default and no AWS credentials.
        service_account_name = each.value.service_account

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
            for_each = each.value.config == null ? [] : [1]
            content {
              name       = "config"
              mount_path = each.value.config.mount_path
              read_only  = true
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
          for_each = each.value.config == null ? [] : [1]
          content {
            name = "config"
            config_map {
              name = kubernetes_config_map_v1.config[each.key].metadata[0].name
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

  # POD IDENTITY IS INJECTED AT POD CREATION, SO THE ASSOCIATION HAS TO EXIST FIRST.
  #
  # A mutating webhook adds AWS_CONTAINER_CREDENTIALS_FULL_URI to a pod only if an association
  # already covers its ServiceAccount. Create the pod first and it comes up with no AWS
  # credentials at all, and stays that way — the webhook never revisits a running pod.
  #
  # Terraform could not infer this ordering. `service_account` is a plain string in var.services
  # rather than a reference to the ServiceAccount resource, so there was no edge in the graph
  # between the deployment and the association, and the first apply created LiteLLM first. It
  # started cleanly and every Bedrock call failed with
  #
  #   litellm.AuthenticationError: BedrockException Invalid Authentication - Unable to locate
  #   credentials
  #
  # which reads like a LiteLLM misconfiguration and is nothing of the kind. The pods needed a
  # rollout restart to pick the credentials up.
  #
  # This makes every service wait on the association, including the datastores that do not want
  # it. That costs one API call's worth of ordering and means a rebuild from empty state works
  # the first time, which the previous version did not.
  depends_on = [aws_eks_pod_identity_association.bedrock]
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
