# Neo4j, standalone, authenticated, on a named StorageClass, reachable only by named clients.
#
# THREE THINGS THE UPSTREAM CHART GETS WRONG FOR THIS PLATFORM, all of them defaults.
#
# 1. `services.neo4j.spec.type` defaults to **LoadBalancer**. On EKS that provisions an
#    internet-facing Network Load Balancer in front of the graph database. Two separate
#    problems: bolt reachable from the internet, and an NLB that no Terraform state knows
#    about — roughly $19.32/month in eu-west-2, whose ENIs then hold the subnets and fail
#    the VPC destroy with DependencyViolation. Overridden to ClusterIP below.
#
# 2. `volumes.data` defaults to a 100Gi claim. Empty graph, $9.28/month. 10Gi here, and gp3
#    is expandable so growing it later is not a recreate.
#
# 3. Authentication. The configuration this replaces set `dbms.security.auth_enabled: false`,
#    which made reaching the network sufficient to read and write everything the agent had
#    ever been told. Fixed here, and fixed *structurally* — see the note on the Secret.

locals {
  # The bolt address consumers use. Constructed from the same values the chart derives its
  # own object names from, so it cannot drift from what actually exists.
  bolt_host = "${var.name}.${var.namespace}.svc.cluster.local"

  # ONE DEFINITION, read by both the chart values and the inventory output.
  #
  # These were two separate literals. The inventory said "ClusterIP" while the chart values
  # said "ClusterIP" independently, so changing one left the other still claiming the safe
  # answer — and the test, which read the inventory, kept passing. Verified by mutation:
  # flipping the chart value to LoadBalancer did not fail a single test.
  #
  # Sharing the local means they cannot disagree. The test additionally asserts against the
  # rendered YAML the release actually receives, so neither this nor the inventory is taken
  # on trust.
  service_type = "ClusterIP"

  common_labels = merge(var.labels, {
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/name"       = "neo4j"
    "app.kubernetes.io/instance"   = var.name
    "eaf.io/module"                = "neo4j"
  })

  # An allow policy is only worth creating if something enforces it — and unlike a
  # default-deny, an unenforced allow policy is not merely useless, it is misleading: the
  # deny it was written against is equally unenforced, so the database is open.
  create_policy = var.network_policy_enforced && (
    length(var.allowed_client_namespaces) > 0 || var.allow_same_namespace
  )
}

# ── The credential ────────────────────────────────────────────────────────────
#
# ALPHANUMERIC ONLY, WHICH IS NOT A STYLE CHOICE.
#
# The chart reads this value back through two shell pipelines. `_helpers.tpl` builds
# `kubectl get secret ... | cut -d '/' -f2` to recover the password, so a password containing
# a forward slash is silently truncated at the slash — the release installs, and
# authentication then fails with bad credentials that match nothing anyone typed.
#
# The chart also validates the value with the regex `^neo4j\/\w*`, which only matches word
# characters. Because it uses a find rather than a full match, a password with punctuation
# passes validation and then breaks at the `cut`. So the validation does not protect against
# the thing that actually goes wrong.
#
# 32 alphanumeric characters is about 190 bits, which is more entropy than a symbol set buys.
resource "random_password" "neo4j" {
  length  = var.password_length
  special = false
  upper   = true
  lower   = true
  numeric = true
}

# THE `neo4j/` PREFIX IS MANDATORY AND EASY TO MISS.
#
# The chart expects `NEO4J_AUTH` to hold `<username>/<password>`, not a bare password, and
# validates it starts with `neo4j/`. A Secret containing just the password fails the release
# with "Password in secret ... must start with the characters 'neo4j/'" — which reads like a
# password policy rather than a format requirement.
#
# The key name is equally load-bearing: anything other than `NEO4J_AUTH` fails with
# "Secret ... must contain key NEO4J_AUTH".
#
# WHY THIS SECRET EXISTS AT ALL, rather than passing `neo4j.password` to the chart.
# `neo4j.passwordFromSecret` was added upstream specifically to fix a data race with
# Terraform and Argo: given a password, the chart creates the Secret itself, and on a second
# apply the chart's `lookup` of its own Secret races with the release it belongs to. Owning
# the Secret here removes the race, and keeps the generated value out of the rendered chart
# values that appear in a plan.
resource "kubernetes_secret_v1" "auth" {
  metadata {
    name      = "${var.name}-auth"
    namespace = var.namespace
    labels    = local.common_labels
  }

  data = {
    NEO4J_AUTH = "neo4j/${random_password.neo4j.result}"
  }

  type = "Opaque"
}

# ── The release ───────────────────────────────────────────────────────────────

module "release" {
  source = "../helm-release"

  name      = var.name
  namespace = var.namespace

  repository    = "https://helm.neo4j.com/neo4j"
  chart         = "neo4j"
  chart_version = var.chart_version

  # Waiting matters more here than anywhere else so far: this is the first workload that
  # provisions a volume, so "the release is ready" is the only signal that dynamic
  # provisioning through the EBS CSI driver actually works.
  wait            = true
  timeout_seconds = 900

  values = {
    neo4j = {
      name = var.name

      # Community edition needs no licence. It is single-database and non-clustered, which
      # is what a standalone instance is anyway.
      edition = "community"

      # AUTHENTICATION IS ON BY CONSTRUCTION, not by a flag set correctly.
      #
      # Setting passwordFromSecret while also setting dbms.security.auth_enabled=false is a
      # hard template failure in the chart: "Cannot set neo4j.password or
      # neo4j.passwordFromSecret when Neo4j auth is disabled". So this module cannot produce
      # an unauthenticated Neo4j — the two settings are mutually exclusive upstream, and
      # that is a stronger guarantee than remembering not to disable it.
      passwordFromSecret = kubernetes_secret_v1.auth.metadata[0].name

      resources = {
        cpu    = var.cpu_request
        memory = var.memory_request
      }
    }

    # ── The volume ──────────────────────────────────────────────────────────
    #
    # `dynamic` mode names the class. The gp3 class uses WaitForFirstConsumer, which is what
    # makes a zonal volume safe here: the volume is created in whichever zone the pod was
    # scheduled into, rather than being created first and then constraining the scheduler to
    # a zone that may have no capacity.
    volumes = {
      data = {
        mode = "dynamic"
        dynamic = {
          storageClassName = var.storage_class_name
          accessModes      = ["ReadWriteOnce"]
          requests = {
            storage = var.storage_size
          }
        }
      }
    }

    # ── Services ────────────────────────────────────────────────────────────
    #
    # ClusterIP, overriding the chart's LoadBalancer default. See the header comment: the
    # default exposes bolt to the internet and leaks an NLB on teardown.
    #
    # Reaching the browser is a `kubectl port-forward`, which does not traverse a Service
    # and so needs nothing opened here.
    services = {
      neo4j = {
        enabled = true
        spec = {
          type = local.service_type
        }
      }
    }

    config = {
      # The chart sets this to "false" by default. Left as the chart has it: strict
      # validation rejects unknown configuration keys, and the chart itself emits keys that
      # vary by version.
      "server.config.strict_validation.enabled" = "false"
    }

    # Triggers and UUID generation, both of which Graphiti calls.
    apoc_config = var.apoc_enabled ? {
      "apoc.trigger.enabled" = "true"
      "apoc.uuid.enabled"    = "true"
    } : {}

    # The initial password would otherwise be written to the pod log in clear text.
    logInitialPassword = false
  }
}

# ── Who may talk to the database ──────────────────────────────────────────────
#
# The namespace already denies all ingress by default, so this policy is what lets anything
# in. It names bolt explicitly rather than admitting the pod wholesale: 7474 is the HTTP
# browser and 7687 is the database protocol, and only one of those is something a workload
# should be able to reach.
resource "kubernetes_network_policy_v1" "allow_bolt" {
  count = local.create_policy ? 1 : 0

  metadata {
    name      = "${var.name}-allow-bolt"
    namespace = var.namespace
    labels    = local.common_labels
  }

  spec {
    # Selects the chart's pods. The chart labels them `app: <neo4j.name>`, which is why this
    # matches on `app` rather than on the app.kubernetes.io/* set this module applies to its
    # own objects.
    pod_selector {
      match_labels = {
        app = var.name
      }
    }

    ingress {
      # Pods in Neo4j's own namespace. An empty pod_selector inside a from block scoped to
      # this namespace means "any pod here", which is what Graphiti needs.
      dynamic "from" {
        for_each = var.allow_same_namespace ? [1] : []
        content {
          pod_selector {}
        }
      }

      # Pods in other named namespaces, selected by the label k8s-namespace sets.
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
        port     = "7687"
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }

  # The release creates the pods this policy selects. Without the edge, a policy can exist
  # selecting nothing, which is indistinguishable from a policy that works.
  depends_on = [module.release]
}
