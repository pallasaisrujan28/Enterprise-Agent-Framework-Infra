# ── Identity ──────────────────────────────────────────────────────────────────

variable "org_prefix" {
  description = "Short organisation prefix, e.g. `eaf`. Combined with environment to name the cluster."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.org_prefix))
    error_message = "org_prefix must be lowercase, 2-12 characters, starting with a letter."
  }
}

variable "environment" {
  description = "dev | test | staging | prod"
  type        = string
  validation {
    condition     = contains(["dev", "test", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, staging, prod."
  }
}

variable "owner" {
  description = "Owning team, recorded as a mandatory tag."
  type        = string
  validation {
    condition     = length(var.owner) >= 3
    error_message = "owner must name a real team."
  }
}

# ── Cluster ───────────────────────────────────────────────────────────────────

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes minor version, e.g. `1.36`. No patch component — EKS manages patches
    through the platform version.

    Pin this deliberately. Omitting it lets AWS choose the current default, which
    changes over time, so two applies months apart would build different clusters
    from identical configuration.
  EOT
  type        = string
  validation {
    condition     = can(regex("^1\\.(3[0-9]|[4-9][0-9])$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor version such as \"1.36\" — no patch component, and 1.30 or later."
  }
}

variable "cluster_role_arn" {
  description = <<-EOT
    ARN of the cluster IAM role, which must trust `eks.amazonaws.com` and carry
    `AmazonEKSClusterPolicy`.

    Taken as an input rather than created here: `modules/iam-role` is the only path
    that creates a role in this repository, and the caller invokes it. Pass the
    module's `.arn` output, never a constructed string.
  EOT
  type        = string
  validation {
    condition     = can(regex("^arn:[a-z-]+:iam::[0-9]{12}:role/", var.cluster_role_arn))
    error_message = "cluster_role_arn must be a full IAM role ARN."
  }
}

variable "subnet_ids" {
  description = <<-EOT
    Subnets for the control plane's cross-account elastic network interfaces. At
    least two, in different availability zones.

    Pass PRIVATE subnets. The set of availability zones given here is durable: AWS
    requires any subnet added to the cluster later to be in the same zones.
  EOT
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two availability zones."
  }
}

variable "endpoint_public_access" {
  description = <<-EOT
    Whether the Kubernetes API endpoint is reachable from the internet.

    `true` here, and narrowed by `public_access_cidrs`, because closing it is a
    later step that needs VPC interface endpoints in place first — a cluster whose
    endpoint is private before those exist is unreachable from the pipeline.
  EOT
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Whether the API endpoint is reachable from inside the VPC. On by default: node-to-control-plane traffic then stays in the VPC rather than traversing the NAT gateway."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = <<-EOT
    CIDRs permitted to reach the public endpoint. Defaults to `0.0.0.0/0`, which is
    also what AWS defaults to when the argument is omitted.

    Stated explicitly rather than left implicit: a wide-open API endpoint should be
    visible in the configuration and in a plan diff, not a default nobody sees.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = length(var.public_access_cidrs) > 0
    error_message = "public_access_cidrs must contain at least one CIDR. To close public access entirely, set endpoint_public_access = false."
  }
}

variable "service_ipv4_cidr" {
  description = <<-EOT
    CIDR from which Kubernetes assigns Service cluster IPs. Optional; AWS picks
    `10.100.0.0/16` or `172.20.0.0/16` when omitted.

    It must not overlap the VPC, and it CANNOT be changed after creation.
  EOT
  type        = string
  default     = null
}

variable "enabled_cluster_log_types" {
  description = <<-EOT
    Control-plane logs to publish to CloudWatch.

    `audit` and `authenticator` are the two that answer "who did this?" — without
    them an access-control question has no evidence. They are not free, which is why
    this is an input, but the default is the useful set rather than the cheap one.
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
  validation {
    condition = alltrue([
      for t in var.enabled_cluster_log_types :
      contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)
    ])
    error_message = "Valid log types are: api, audit, authenticator, controllerManager, scheduler."
  }
}

variable "support_type" {
  description = <<-EOT
    `STANDARD` or `EXTENDED`.

    Defaults to `STANDARD` deliberately. Under `EXTENDED` a cluster that reaches the
    end of standard support keeps running and starts billing at the extended-support
    rate — quietly. `STANDARD` means the version must be upgraded instead, which is
    the behaviour you want to be forced into rather than the bill.
  EOT
  type        = string
  default     = "STANDARD"
  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.support_type)
    error_message = "support_type must be STANDARD or EXTENDED."
  }
}

variable "secrets_kms_key_arn" {
  description = <<-EOT
    KMS key for envelope-encrypting Kubernetes Secrets at rest in etcd.

    Optional, and CANNOT be added after creation — enabling it later requires a new
    cluster. Worth setting for anything holding real credentials.
  EOT
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Refuse to delete the cluster while set. Leave off in a disposable environment; a destroy that cannot complete is its own kind of stuck."
  type        = bool
  default     = false
}

# ── Access ────────────────────────────────────────────────────────────────────

variable "bootstrap_cluster_creator_admin_permissions" {
  description = <<-EOT
    Whether AWS grants cluster-admin to whichever principal created the cluster.

    Defaults to FALSE, which is not the AWS default. Two reasons.

    It is an invisible grant: the resulting admin access does not appear as any
    resource in Terraform, so "who can administer this cluster?" cannot be answered
    from the configuration. `access_entries` below makes every grant explicit and
    reviewable instead.

    And it depends on the identity that happened to run the apply. A cluster created
    by a pipeline role grants that role admin; the same configuration applied from a
    workstation grants a person. Configuration should not mean different things
    depending on who ran it.

    CHANGING THIS FORCES THE CLUSTER TO BE REPLACED. It has to be right the first
    time.
  EOT
  type        = bool
  default     = false
}

variable "access_entries" {
  description = <<-EOT
    Who may reach the Kubernetes API, keyed by a short name used in resource
    addresses. This replaces the deprecated `aws-auth` ConfigMap.

    Each entry names an IAM principal and the access policies to associate. Scope is
    `cluster` or `namespace`; `namespace` requires `namespaces`.
  EOT
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string))
    username          = optional(string)
    policies = optional(list(object({
      policy_arn = string
      scope_type = optional(string, "cluster")
      namespaces = optional(list(string))
    })), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, e in var.access_entries : alltrue([
        for p in e.policies : contains(["cluster", "namespace"], lower(p.scope_type))
      ])
    ])
    error_message = "Each policy scope_type must be \"cluster\" or \"namespace\"."
  }

  # A namespace-scoped association with no namespaces grants nothing, and reports
  # nothing. Caught here rather than discovered when a developer cannot list pods.
  validation {
    condition = alltrue([
      for k, e in var.access_entries : alltrue([
        for p in e.policies :
        lower(p.scope_type) != "namespace" || length(coalesce(p.namespaces, [])) > 0
      ])
    ])
    error_message = "A policy with scope_type = \"namespace\" must list at least one namespace."
  }

  validation {
    condition = alltrue([
      for k, e in var.access_entries :
      can(regex("^arn:[a-z-]+:iam::[0-9]{12}:(role|user)/", e.principal_arn))
    ])
    error_message = "Each access entry principal_arn must be a full IAM role or user ARN."
  }

  # An EKS access policy ARN, not an IAM policy ARN. They look similar and the
  # mistake is rejected by the API with a message that does not say which is wrong.
  validation {
    condition = alltrue([
      for k, e in var.access_entries : alltrue([
        for p in e.policies : startswith(p.policy_arn, "arn:aws:eks::aws:cluster-access-policy/")
      ])
    ])
    error_message = "policy_arn must be an EKS ACCESS policy, of the form arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy. An IAM policy ARN is not valid here."
  }
}

# ── Tags ──────────────────────────────────────────────────────────────────────

variable "extra_tags" {
  description = "Additional tags. Merged FIRST, so the module's mandatory tags win on a key collision."
  type        = map(string)
  default     = {}
}
