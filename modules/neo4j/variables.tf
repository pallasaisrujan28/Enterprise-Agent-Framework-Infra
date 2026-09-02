variable "name" {
  description = "Release name. Every object the chart creates derives its name from this, and the bolt address becomes `<name>.<namespace>.svc.cluster.local`."
  type        = string
  default     = "neo4j"
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be a lowercase RFC 1123 label."
  }
}

variable "namespace" {
  description = "Namespace to deploy into. Must already exist — the cluster-addons layer owns namespaces, together with the default-deny policy and quota a Helm-created one would lack."
  type        = string
}

variable "chart_version" {
  description = <<-EOT
    Neo4j Helm chart version, pinned exactly.

    The 5.26 line is the Long Term Support release, supported until June 2028, and 5.26 is
    also the floor Graphiti documents as its minimum. The chart has since moved to calendar
    versioning (2026.x is current), but nothing documents Graphiti against that generation,
    and the graph is the one component whose contents are expensive to rebuild.
  EOT
  type        = string
  default     = "5.26.30"
}

variable "storage_class_name" {
  description = <<-EOT
    StorageClass for the data volume. Named explicitly rather than relying on whichever
    class happens to be marked default.

    The chart offers a `defaultStorageClass` mode that would work here, since `gp3` is the
    default. Naming the class means the volume type is a property of this configuration
    rather than of cluster state that another layer could change.
  EOT
  type        = string
  default     = "gp3"
}

variable "storage_size" {
  description = <<-EOT
    Size of the data volume.

    The chart's own default is 100Gi, which at gp3's $0.0928/GB-month is about $9.28 a
    month for a graph that starts empty. 10Gi is a more honest starting point, and gp3
    volumes can be expanded in place — the cluster-addons StorageClass sets
    allowVolumeExpansion, so growing this later does not mean recreating it.
  EOT
  type        = string
  default     = "10Gi"
  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi|Ti)$", var.storage_size))
    error_message = "storage_size must be a Kubernetes quantity such as 10Gi."
  }
}

variable "cpu_request" {
  description = "CPU request. The chart's default is 1000m, which is half of an m6i.large's two vCPUs before any other workload is placed."
  type        = string
  default     = "500m"
}

variable "memory_request" {
  description = "Memory request. Neo4j sizes its page cache and heap from what it is given, so this is a real performance parameter rather than a limit to be raised when something is killed."
  type        = string
  default     = "2Gi"
}

variable "allowed_client_namespaces" {
  description = <<-EOT
    Namespaces whose pods may open a bolt connection.

    Selected by the `eaf.io/namespace` label, which `modules/k8s-namespace` sets for exactly
    this purpose: a NetworkPolicy in one namespace needs a namespaceSelector to admit traffic
    from another, and selecting on a label this platform controls is clearer than relying on
    the automatic `kubernetes.io/metadata.name`.

    An empty list plus `allow_same_namespace = false` means nothing can reach the database,
    which is a valid state and not an error — it is what you want before a consumer exists.
  EOT
  type        = list(string)
  default     = []
}

variable "allow_same_namespace" {
  description = <<-EOT
    Allow bolt connections from pods in Neo4j's own namespace.

    True by default because Graphiti is deployed into this namespace, and a policy that
    omitted it would present as Graphiti being unable to reach a database that is plainly
    running — a slow thing to diagnose, since every other signal looks healthy.
  EOT
  type        = bool
  default     = true
}

variable "network_policy_enforced" {
  description = <<-EOT
    Whether anything in this cluster actually enforces NetworkPolicy.

    An ASSERTION, mirroring `modules/k8s-namespace`. Nothing here turns enforcement on; that
    is the vpc-cni add-on's `enableNetworkPolicy` in the platform layer.

    It matters more here than for a default-deny rule. The namespace already denies ingress,
    so this module's policy is what ALLOWS bolt through. If enforcement is off, the allow
    policy is inert and so is the deny it was written against — the database is reachable
    from anywhere in the cluster, and every object involved looks correctly configured.
  EOT
  type        = bool
  default     = true
}

variable "password_length" {
  description = "Length of the generated password. Alphanumeric only, so 32 characters is roughly 190 bits."
  type        = number
  default     = 32
  validation {
    condition     = var.password_length >= 16
    error_message = "password_length must be at least 16."
  }
}

variable "apoc_enabled" {
  description = <<-EOT
    Enable the APOC procedures Graphiti relies on — triggers and UUID generation.

    APOC ships in the Neo4j image; this only permits the two procedure groups. Left on
    because Graphiti fails at query time without them, with an error naming a missing
    procedure rather than a missing configuration flag.
  EOT
  type        = bool
  default     = true
}

variable "labels" {
  description = "Extra labels for the objects this module creates. Merged first, so the module's own labels win on collision."
  type        = map(string)
  default     = {}
}
