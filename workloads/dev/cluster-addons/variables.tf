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

variable "network_policy_enforced" {
  description = <<-EOT
    Whether something in this cluster actually enforces NetworkPolicy.

    An ASSERTION, not a switch — nothing here turns enforcement on. That happens in L1,
    where the vpc-cni add-on is configured with `enableNetworkPolicy = "true"`.

    It exists because the failure it guards against is silent. A NetworkPolicy with no
    enforcer is stored by the API server, listed by kubectl, shown by describe as
    selecting every pod, and ignored entirely. Set this to false and the namespaces are
    created with no policy and a label saying why, rather than with something that reads
    as protection.

    Verified before enabling: the aws-eks-nodeagent container was already running with
    `--enable-network-policy=false`, so its presence is not evidence.
  EOT
  type        = bool
  default     = true
}

variable "namespaces" {
  description = <<-EOT
    The namespaces this layer owns, and each one's baseline.

    Quotas are set where a namespace holds something whose overuse produces a bill rather
    than a Pending pod — `persistentvolumeclaims` in particular, since each one becomes an
    EBS volume.
  EOT
  type = map(object({
    resource_quota = optional(map(string))
    limit_range = optional(object({
      default_request_cpu    = optional(string)
      default_request_memory = optional(string)
      default_limit_cpu      = optional(string)
      default_limit_memory   = optional(string)
    }))
  }))

  default = {
    # The agent itself.
    eaf = {
      limit_range = {
        default_request_cpu    = "100m"
        default_request_memory = "128Mi"
        default_limit_memory   = "1Gi"
      }
    }

    # Langfuse and its sub-charts: postgres, valkey, clickhouse, seaweedfs.
    monitoring = {
      resource_quota = {
        "persistentvolumeclaims" = "8"
      }
      limit_range = {
        default_request_cpu    = "100m"
        default_request_memory = "256Mi"
        default_limit_memory   = "2Gi"
      }
    }

    # Neo4j, and Graphiti later.
    memory = {
      resource_quota = {
        "persistentvolumeclaims" = "4"
      }
      limit_range = {
        default_request_cpu    = "250m"
        default_request_memory = "1Gi"
        default_limit_memory   = "4Gi"
      }
    }

    # Firecrawl's five services.
    tools = {
      resource_quota = {
        "persistentvolumeclaims" = "4"
      }
      limit_range = {
        default_request_cpu    = "100m"
        default_request_memory = "256Mi"
        default_limit_memory   = "2Gi"
      }
    }
  }

  validation {
    condition     = alltrue([for n, _ in var.namespaces : !startswith(n, "kube-")])
    error_message = "kube-* namespaces belong to Kubernetes and must not be managed here."
  }
}

# ── Storage ───────────────────────────────────────────────────────────────────

variable "storage_class_name" {
  description = "Name of the StorageClass this layer creates. Workloads put this in `storageClassName`."
  type        = string
  default     = "gp3"
}

variable "storage_encrypted" {
  description = "Encrypt EBS volumes provisioned through the StorageClass. On by default — encryption at rest should not require remembering."
  type        = bool
  default     = true
}

variable "storage_kms_key_id" {
  description = "CMK for volume encryption. Null uses the AWS-managed EBS key, which is adequate and has no key policy to maintain."
  type        = string
  default     = null
}
