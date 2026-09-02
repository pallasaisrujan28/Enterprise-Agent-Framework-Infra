variable "name" {
  description = "Name prefix for every object. Service DNS becomes `<name>-api.<namespace>.svc.cluster.local`."
  type        = string
  default     = "firecrawl"
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be a lowercase RFC 1123 label."
  }
}

variable "namespace" {
  description = "Namespace to deploy into. Owned by the cluster-addons layer, along with its default-deny NetworkPolicy, PVC quota and LimitRange."
  type        = string
}

variable "registry" {
  description = "ECR registry host, e.g. `718438899462.dkr.ecr.eu-west-2.amazonaws.com`. Read from the platform layer rather than hardcoded."
  type        = string
}

variable "image_tag" {
  description = <<-EOT
    Commit SHA of the images to deploy. The SAME tag for all three, because they are built
    from one repository state by one workflow run.

    Property 5 requires a 40-character SHA rather than a moving tag: a deployed reference must
    identify exactly one set of bytes, which is what makes a rollback meaningful.
  EOT
  type        = string
  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.image_tag))
    error_message = "image_tag must be a 40-character lowercase commit SHA. A moving tag such as `latest` makes a deploy non-deterministic and a rollback impossible."
  }
}

# ── Capacity ──────────────────────────────────────────────────────────────────

variable "workloads" {
  description = <<-EOT
    The workloads, their replica counts and their resource requests.

    SHRUNK HEAVILY FROM UPSTREAM, deliberately, because upstream's defaults do not fit this
    cluster. Their Helm chart asks for roughly 10,250m CPU and ~26.5 GB of requests, against
    two m6i.large offering about 3,860m and 14.3 GiB with Neo4j already resident. Property 9
    would reject it outright.

    Most of the reduction is one number: `nuq-worker` ships at FIVE replicas requesting 1000m
    and 3G each — 5,000m and 15 GB by itself. One replica is enough for a cluster with no
    consumer yet, and replicas are the correct dial to turn when crawl throughput actually
    matters.

    Nothing is set to zero replicas. It is tempting for `extract-worker` in particular, since
    LLM extraction needs an API key this platform does not supply — but a worker turned off
    without understanding what drains its queue is a silent functional gap, and a small
    request is cheaper than that risk.
  EOT

  type = map(object({
    replicas = number
    cpu      = string
    memory   = string
    # Which container image this workload runs. `api` covers the API and every worker; they
    # are the same image with different entrypoints, which is why upstream's compose can run
    # them in one container and its Helm chart splits them.
    image   = string
    command = optional(list(string))
    port    = optional(number)
  }))

  default = {
    api = {
      replicas = 1
      cpu      = "300m"
      memory   = "1Gi"
      image    = "api"
      port     = 3002
    }
    worker = {
      replicas = 1
      cpu      = "200m"
      memory   = "768Mi"
      image    = "api"
      command  = ["node", "dist/src/services/queue-worker.js"]
    }
    extract-worker = {
      replicas = 1
      cpu      = "100m"
      memory   = "512Mi"
      image    = "api"
      command  = ["node", "dist/src/services/extract-worker.js"]
    }
    nuq-worker = {
      replicas = 1
      cpu      = "250m"
      memory   = "768Mi"
      image    = "api"
      command  = ["node", "dist/src/services/nuq-worker.js"]
    }
    nuq-prefetch-worker = {
      replicas = 1
      cpu      = "100m"
      memory   = "256Mi"
      image    = "api"
      command  = ["node", "dist/src/services/nuq-prefetch-worker.js"]
    }
    cclog-worker = {
      replicas = 1
      cpu      = "50m"
      memory   = "192Mi"
      image    = "api"
      command  = ["node", "dist/src/services/cclog-worker.js"]
    }
    playwright = {
      replicas = 1
      cpu      = "200m"
      memory   = "1Gi"
      image    = "playwright"
      port     = 3000
    }
    redis = {
      replicas = 1
      cpu      = "50m"
      memory   = "128Mi"
      image    = "redis"
      port     = 6379
    }
    rabbitmq = {
      replicas = 1
      cpu      = "100m"
      memory   = "256Mi"
      image    = "rabbitmq"
      port     = 5672
    }
    nuq-postgres = {
      replicas = 1
      cpu      = "100m"
      memory   = "256Mi"
      image    = "postgres"
      port     = 5432
    }
  }
}

variable "cpu_budget_millicores" {
  description = <<-EOT
    Ceiling on the sum of CPU requests across every workload and replica.

    A PRECONDITION, NOT DOCUMENTATION. Property 9 says declared requests must fit declared
    capacity, and the way that property gets violated is by someone raising a replica count
    without doing the arithmetic. Doing it here means the plan fails with the numbers in the
    message instead of pods sitting Pending with `Insufficient cpu` — which is precisely the
    state this cluster was in before the rebuild.

    1600m against roughly 2,680m free after kube-system and Neo4j, measured on the live
    cluster. The gap is headroom for scheduling, not slack to be spent.
  EOT
  type        = number
  default     = 1600
}

variable "memory_budget_mib" {
  description = "Ceiling on the sum of memory requests. 6144Mi against roughly 11,440Mi free, measured live."
  type        = number
  default     = 6144
}

# ── Storage ───────────────────────────────────────────────────────────────────

variable "postgres_storage_size" {
  description = "Size of the queue database volume. The queue holds in-flight jobs, not crawl output, so it does not grow with usage."
  type        = string
  default     = "8Gi"
}

variable "storage_class_name" {
  description = "StorageClass for the queue volume. Named explicitly rather than relying on whichever class is default."
  type        = string
  default     = "gp3"
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "allowed_client_namespaces" {
  description = <<-EOT
    Namespaces whose pods may reach the Firecrawl API.

    Selected by the `eaf.io/namespace` label that `modules/k8s-namespace` sets.

    This matters more here than for most services. Firecrawl's API authentication is OFF in
    the self-hosted default — `USE_DB_AUTHENTICATION=false` — and upstream's own documentation
    is explicit that the baseline must not be exposed to untrusted networks. The NetworkPolicy
    is therefore the only access control in front of it, not a second layer behind an API key.
  EOT
  type        = list(string)
  default     = []
}

variable "network_policy_enforced" {
  description = <<-EOT
    Whether anything in this cluster actually enforces NetworkPolicy.

    An assertion, mirroring modules/k8s-namespace and modules/neo4j. Nothing here turns
    enforcement on; that is the vpc-cni add-on in the platform layer.

    Load-bearing for this module specifically: with authentication off, an unenforced policy
    means the API is reachable and unauthenticated from anywhere in the cluster, while every
    object involved looks correctly configured.
  EOT
  type        = bool
  default     = true
}

variable "labels" {
  description = "Extra labels for every object. Merged first, so the module's own labels win on collision."
  type        = map(string)
  default     = {}
}
