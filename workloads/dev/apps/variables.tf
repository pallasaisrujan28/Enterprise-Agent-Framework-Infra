variable "account_id" {
  description = "EAF-DEV account ID."
  type        = string
  default     = "718438899462"
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  description = "AWS region the cluster is in."
  type        = string
  default     = "eu-west-2"
}

variable "memory_namespace" {
  description = <<-EOT
    Namespace the memory stack goes into. Owned by the cluster-addons layer, which also
    attaches its default-deny NetworkPolicy, its PVC quota and its LimitRange.

    Neo4j previously lived in `tools`, which meant memory and tool workloads competed for one
    node. The bolt address moves with the namespace, so anything holding the old
    `neo4j.tools.svc.cluster.local` would silently fail to resolve.
  EOT
  type        = string
  default     = "memory"
}

variable "neo4j_storage_size" {
  description = <<-EOT
    Size of the Neo4j data volume.

    The chart's own default is 100Gi, about $9.28/month at gp3 rates for a graph that starts
    empty. gp3 allows expansion in place, so this can grow without a recreate.
  EOT
  type        = string
  default     = "10Gi"
}

variable "neo4j_chart_version" {
  description = "Neo4j Helm chart version, pinned. The 5.26 line is LTS to June 2028 and is the floor Graphiti documents."
  type        = string
  default     = "5.26.30"
}

variable "neo4j_client_namespaces" {
  description = <<-EOT
    Namespaces whose pods may open a bolt connection to Neo4j.

    Empty by default, and that is deliberate rather than an oversight. Nothing consumes the
    graph yet: Graphiti arrives in its own step and lands in the memory namespace, which is
    admitted separately. Opening `eaf` now would grant access to a workload that does not
    exist and cannot currently start.
  EOT
  type        = list(string)
  default     = []
}

# ── Firecrawl ─────────────────────────────────────────────────────────────────

variable "firecrawl_image_tag" {
  description = <<-EOT
    Commit SHA of the Firecrawl images to deploy, or null to not deploy Firecrawl at all.

    NULL BY DEFAULT, AND THAT IS PROPERTY 6 EXPRESSED AS A VARIABLE.

    Images must exist before anything references them. The three Firecrawl images are built by
    this repository's `build-images` workflow, which is dispatch-only — so until it has run,
    there is nothing to deploy and a tag would name an image that cannot be pulled. The
    failure mode of getting this wrong is ImagePullBackOff, which reads as a registry
    permissions problem rather than an absent image.

    So Firecrawl is opt-in: dispatch build-images, take the commit SHA it tagged, set it here.
    The layer applies cleanly either way, which is what lets Neo4j land before Firecrawl does.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.firecrawl_image_tag == null || can(regex("^[0-9a-f]{40}$", var.firecrawl_image_tag))
    error_message = "firecrawl_image_tag must be null or a 40-character lowercase commit SHA."
  }
}

variable "firecrawl_namespace" {
  description = "Namespace for the Firecrawl stack. Separate from `memory` so a tool backend and the graph do not share a failure domain."
  type        = string
  default     = "tools"
}

variable "firecrawl_client_namespaces" {
  description = <<-EOT
    Namespaces whose pods may reach the Firecrawl API.

    Empty by default. Firecrawl's self-hosted API has no authentication, so this list is the
    only thing standing in front of it — and nothing consumes it yet. Opening `eaf` now would
    admit a workload that cannot currently start.
  EOT
  type        = list(string)
  default     = []
}
