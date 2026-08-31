variable "org_prefix" {
  description = "Short organisation prefix, e.g. `eaf`."
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

variable "pool" {
  description = <<-EOT
    Short name for this pool, e.g. `default` or `memory`. Appears in the node group
    name, so it distinguishes pools within one cluster.
  EOT
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.pool))
    error_message = "pool must be lowercase kebab-case, 2-21 characters, starting with a letter."
  }
}

variable "cluster_name" {
  description = "Cluster to join. Pass `module.eks_cluster.name` so the dependency is real rather than a coincidence of apply order."
  type        = string
}

variable "node_role_arn" {
  description = <<-EOT
    ARN of the node IAM role. It must trust `ec2.amazonaws.com` and carry
    `AmazonEKSWorkerNodePolicy` and `AmazonEC2ContainerRegistryPullOnly`.

    It should NOT carry `AmazonEKS_CNI_Policy`. That policy lets its holder attach and
    detach network interfaces and assign IP addresses; on the node role, every pod on
    the node inherits it through the instance metadata service. It belongs on the
    vpc-cni add-on's own Pod Identity role instead.

    Taken as an input rather than created here: `modules/iam-role` is the only path
    that creates a role in this repository.
  EOT
  type        = string
  validation {
    condition     = can(regex("^arn:[a-z-]+:iam::[0-9]{12}:role/", var.node_role_arn))
    error_message = "node_role_arn must be a full IAM role ARN."
  }
}

variable "subnet_ids" {
  description = "Subnets for the nodes. Pass PRIVATE subnets: nodes pull outbound through the NAT gateway and nothing should reach them from the internet."
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "at least one subnet is required."
  }
}

# ── Capacity ──────────────────────────────────────────────────────────────────

variable "instance_types" {
  description = <<-EOT
    Instance types for the pool. A managed node group uses the first that has
    capacity, so order matters.

    Must be Nitro-based when prefix delegation is on — see `nitro_confirmed` below.
  EOT
  type        = list(string)
  validation {
    condition     = length(var.instance_types) >= 1
    error_message = "at least one instance type is required."
  }
  validation {
    condition = alltrue([
      for t in var.instance_types : can(regex("^[a-z][a-z0-9-]*\\.[a-z0-9]+$", t))
    ])
    error_message = "each instance type must look like m6i.large."
  }
  # t2 is the family most likely to be reached for by habit and is NOT Nitro, so
  # prefix delegation silently does nothing on it. Named explicitly because the
  # general Nitro question cannot be answered from a type string alone.
  validation {
    condition = alltrue([
      for t in var.instance_types : !startswith(t, "t2.")
    ])
    error_message = "t2 instances are not built on the Nitro system, so prefix delegation cannot work on them. Use t3, t4g, m5, m6i or newer."
  }
}

variable "desired_size" {
  description = "Nodes to run now. Raise this as workloads land rather than sizing for the end state before anything is deployed."
  type        = number
  validation {
    condition     = var.desired_size >= 0
    error_message = "desired_size cannot be negative."
  }
}

variable "min_size" {
  description = "Lower bound for the autoscaling group."
  type        = number
  validation {
    condition     = var.min_size >= 0
    error_message = "min_size cannot be negative."
  }
}

variable "max_size" {
  description = "Upper bound for the autoscaling group."
  type        = number
  validation {
    condition     = var.max_size >= 1
    error_message = "max_size must be at least 1."
  }
}

variable "capacity_type" {
  description = "`ON_DEMAND` or `SPOT`. Spot nodes are reclaimed with two minutes' notice, which is fine for stateless work and not for a database with a PVC."
  type        = string
  default     = "ON_DEMAND"
  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "ami_type" {
  description = <<-EOT
    `AL2023_x86_64_STANDARD`, `AL2023_ARM_64_STANDARD`, `BOTTLEROCKET_x86_64`, and so
    on. Amazon Linux 2 types are end-of-life and deliberately not defaulted to.

    The architecture must match `instance_types`: an ARM AMI on an x86 instance fails
    at launch with a message about the image, not about the mismatch.
  EOT
  type        = string
  default     = "AL2023_x86_64_STANDARD"
  validation {
    condition = contains([
      "AL2023_x86_64_STANDARD", "AL2023_x86_64_NVIDIA", "AL2023_x86_64_NEURON",
      "AL2023_ARM_64_STANDARD", "AL2023_ARM_64_NVIDIA",
      "BOTTLEROCKET_x86_64", "BOTTLEROCKET_ARM_64",
      "BOTTLEROCKET_x86_64_NVIDIA", "BOTTLEROCKET_ARM_64_NVIDIA",
    ], var.ami_type)
    error_message = "ami_type must be a current AL2023 or Bottlerocket type. Amazon Linux 2 (AL2_*) has reached end of life."
  }
}

variable "disk_size" {
  description = "Root volume size in GiB. Container images are larger than they look; 20 GiB is the AWS default and is tight once a few images are cached."
  type        = number
  default     = 50
  validation {
    condition     = var.disk_size >= 20
    error_message = "disk_size must be at least 20 GiB."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for the nodes. Leave null to follow the cluster, which is what you want unless deliberately staging an upgrade."
  type        = string
  default     = null
  validation {
    condition     = var.kubernetes_version == null || can(regex("^1\\.(3[0-9]|[4-9][0-9])$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor version such as \"1.36\", or null to follow the cluster."
  }
}

# ── Scheduling ────────────────────────────────────────────────────────────────

variable "labels" {
  description = "Kubernetes labels applied to every node in this pool. Output again, so a workload's nodeSelector can be derived from what exists rather than restated."
  type        = map(string)
  default     = {}
}

variable "taints" {
  description = <<-EOT
    Taints applied to every node in this pool, so only workloads with a matching
    toleration schedule here.

    Output again, so a workload's tolerations are derived from the taint that exists
    rather than from a comment. A taint whose toleration was copied by hand and then
    drifted is a pool nothing can schedule on, and the symptom is `Pending` pods with
    a message nobody reads.
  EOT
  type = map(object({
    key    = string
    value  = optional(string)
    effect = string
  }))
  default = {}
  validation {
    condition = alltrue([
      for k, t in var.taints :
      contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], t.effect)
    ])
    error_message = "taint effect must be NO_SCHEDULE, NO_EXECUTE or PREFER_NO_SCHEDULE — the EKS API spelling, not the Kubernetes manifest spelling (NoSchedule)."
  }
}

# ── Rollout ───────────────────────────────────────────────────────────────────

variable "max_unavailable" {
  description = "Nodes that may be unavailable at once during a version update. 1 is slow and safe."
  type        = number
  default     = 1
  validation {
    condition     = var.max_unavailable >= 1
    error_message = "max_unavailable must be at least 1."
  }
}

variable "enable_node_repair" {
  description = "Let EKS replace nodes it detects as unhealthy. Off by default: automatic replacement while diagnosing a problem removes the evidence."
  type        = bool
  default     = false
}

variable "create_timeout" {
  description = "Timeout for node group creation. Generous because a node group whose CNI is missing waits rather than failing fast, and the timeout message is the signal."
  type        = string
  default     = "30m"
}

variable "extra_tags" {
  description = "Additional tags. Merged FIRST, so mandatory tags win on a key collision."
  type        = map(string)
  default     = {}
}
