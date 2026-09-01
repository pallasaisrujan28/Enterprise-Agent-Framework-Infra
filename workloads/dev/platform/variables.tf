variable "account_id" {
  description = "EAF-DEV account ID. Never changes after account creation."
  type        = string
  default     = "718438899462"
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  description = "AWS region for this layer."
  type        = string
  default     = "eu-west-2"
}

variable "org_prefix" {
  description = "Short organisation prefix. Every generated name starts with it."
  type        = string
  default     = "eaf"
}

variable "environment" {
  description = "Environment name. Part of every generated name."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owning team, recorded as a mandatory tag on everything this layer creates."
  type        = string
  default     = "platform-team"
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Availability zones to use. Two is the EKS minimum."
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "One NAT gateway shared by every private subnet. True in dev: cheaper, and one AZ failure removing egress is acceptable here."
  type        = bool
  default     = true
}

# ── Cluster ───────────────────────────────────────────────────────────────────

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes minor version.

    1.36 verified in eu-west-2 on 2026-08-31: STANDARD_SUPPORT, currently the AWS
    default, standard support to 2027-08-02.
  EOT
  type        = string
  default     = "1.36"
}

variable "public_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the Kubernetes API endpoint.

    0.0.0.0/0 for now, because the pipeline reaches the endpoint from GitHub-hosted
    runners whose addresses are not fixed. Narrowing this is Step 10's job, together
    with the VPC interface endpoints that make a private endpoint reachable.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "additional_cluster_admin_role_arns" {
  description = <<-EOT
    Extra IAM roles to grant cluster-admin, named explicitly.

    For IAM Identity Center roles use `sso_admin_permission_sets` instead — those are
    discovered, so the random suffix in their name is not written down anywhere.

    A path in the ARN is fine here. AWS documents that an access entry's principal ARN
    MAY include a path; it is the deprecated `aws-auth` ConfigMap that could not. Worth
    stating because the two rules are easy to conflate, and the earlier version of this
    file assumed the stricter one.
  EOT
  type        = list(string)
  default     = []
}

variable "sso_admin_permission_sets" {
  description = <<-EOT
    IAM Identity Center permission set names whose roles get cluster-admin.

    Discovered at plan time rather than named, because the IAM role Identity Center
    creates for a permission set carries a random suffix — here
    `AWSReservedSSO_AWSAdministratorAccess_a8fd6486dea1ff46`. That suffix CHANGES if the
    permission set is reprovisioned or the account is re-enrolled, and AWS is explicit
    that an access entry stops working when its principal is recreated even at the same
    ARN, because the underlying role id differs. Hardcoding it would work until it
    silently did not.

    Names are matched anchored, which matters: this account has both
    `AdministratorAccess` and `AWSAdministratorAccess`, and a loose pattern would grant
    cluster-admin to a permission set nobody asked for.

    Set to `[]` to grant no human access — the deployer role alone can then reach the
    cluster, which is correct for prod and inconvenient for dev.
  EOT
  type        = list(string)
  default     = ["AWSAdministratorAccess"]
}

# ── Add-on versions ───────────────────────────────────────────────────────────
#
# All five verified as the AWS default for Kubernetes 1.36 in eu-west-2 on
# 2026-08-31:
#   aws eks describe-addon-versions --kubernetes-version 1.36 --addon-name NAME
#
# Pinned rather than omitted. Omitting a version installs whatever is default at
# apply time, so two applies from identical configuration would install different
# software and the difference would read as drift rather than as a decision.

variable "addon_versions" {
  description = "Exact add-on versions. Each must be the full version string including the leading v."
  type = object({
    vpc_cni            = string
    kube_proxy         = string
    coredns            = string
    ebs_csi_driver     = string
    pod_identity_agent = string
  })
  default = {
    vpc_cni            = "v1.22.4-eksbuild.3"
    kube_proxy         = "v1.36.0-eksbuild.17"
    coredns            = "v1.14.3-eksbuild.14"
    ebs_csi_driver     = "v1.65.0-eksbuild.1"
    pod_identity_agent = "v1.3.10-eksbuild.3"
  }
}

# ── Node group ────────────────────────────────────────────────────────────────

variable "node_instance_types" {
  description = <<-EOT
    Instance types for the default pool.

    m6i.large — 2 vCPU, 8 GiB, non-burstable, Nitro. Chosen over t3.medium because
    the tool stack needs memory rather than burst credits, and over t3.large because
    a burstable instance running steadily is the wrong shape.
  EOT
  type        = list(string)
  default     = ["m6i.large"]
}

variable "node_desired_size" {
  description = <<-EOT
    Nodes to run now.

    Two, deliberately low. This layer's acceptance test is that nodes reach Ready and
    the add-ons go Active — not that the whole tool stack fits. Raised as workloads
    land, rather than sized for the end state before anything is deployed.
  EOT
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Lower bound for the node pool."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Upper bound for the node pool. Room to grow without editing this file for every workload."
  type        = number
  default     = 6
}

variable "node_disk_size" {
  description = "Root volume per node, GiB."
  type        = number
  default     = 50
}
