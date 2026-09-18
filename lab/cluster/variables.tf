variable "org_prefix" {
  description = "Name prefix. The cluster is named org_prefix-environment, so eaf + lab gives eaf-lab."
  type        = string
  default     = "eaf"
}

variable "environment" {
  description = "Environment name. `lab` keeps every name distinct from the `dev` cluster `workloads/` builds, so both can exist at once."
  type        = string
  default     = "lab"
}

variable "owner" {
  description = "Owner tag."
  type        = string
  default     = "platform-team"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-2"
}

variable "operator_permission_set" {
  description = <<-EOT
    SSO permission set name whose role becomes cluster administrator.

    The role ARN is discovered from this rather than hardcoded, because the suffix on an SSO
    role name is a permission-set id that changes if the set is recreated — and a hardcoded
    one produces a cluster nobody can reach after an unrelated SSO change.

    Matched anchored (`^AWSReservedSSO_<name>_[0-9a-f]+$`), which matters because this account
    has BOTH `AdministratorAccess` and `AWSAdministratorAccess`.
  EOT
  type        = string
  default     = "AWSAdministratorAccess"
}

variable "vpc_cidr" {
  description = "VPC CIDR. /16 gives room for prefix delegation to hand out /28s per ENI without exhausting subnets."
  type        = string
  default     = "10.1.0.0/16"
}

variable "kubernetes_version" {
  description = "Cluster version. 1.36 is the current default and on STANDARD support, verified live."
  type        = string
  default     = "1.36"
}

variable "instance_types" {
  description = <<-EOT
    Node instance types.

    `m6i.xlarge` — 4 vCPU / 16 GiB — rather than the `m6i.large` `workloads/` uses. The
    memory and RL stack does not fit two larges: Neo4j, Qdrant, Postgres, Redis, MLflow and a
    Ray head alone ask for more than 3,860m of CPU requests.

    Non-burstable on purpose. A `t3` has CPU credits, and an RL loop that runs for an hour
    exhausts them and then throttles — which presents as the workload mysteriously slowing
    down rather than as anything resembling a resource limit.
  EOT
  type        = list(string)
  default     = ["m6i.xlarge"]
}

variable "node_count" {
  description = "Desired node count. Two gives ~8 vCPU and ~29 GiB allocatable, which the stack fits inside with headroom."
  type        = number
  default     = 2
}

variable "node_disk_size" {
  description = "Root volume per node, GiB. Container images for Ray and the ML stack are large — 20 GiB fills up and evicts pods on disk pressure."
  type        = number
  default     = 60
}

variable "addon_versions" {
  description = <<-EOT
    Add-on versions, pinned.

    Verified live against `aws eks describe-addon-versions` for Kubernetes 1.36 — these are
    the current default versions, not remembered ones.

    Pinned rather than left to AWS's default because an unpinned add-on changes under you on
    the next apply, and the resulting diff arrives in a plan that changed nothing else.
  EOT
  type = object({
    vpc_cni            = string
    kube_proxy         = string
    coredns            = string
    ebs_csi            = string
    pod_identity_agent = string
  })
  default = {
    vpc_cni            = "v1.22.4-eksbuild.3"
    kube_proxy         = "v1.36.0-eksbuild.17"
    coredns            = "v1.14.3-eksbuild.14"
    ebs_csi            = "v1.65.0-eksbuild.1"
    pod_identity_agent = "v1.3.10-eksbuild.3"
  }
}
