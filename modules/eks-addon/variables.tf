variable "org_prefix" {
  description = "Short organisation prefix, e.g. `eaf`. Recorded as a tag."
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

variable "cluster_name" {
  description = "Name of the cluster. Pass `module.eks_cluster.name` so the dependency is real, not a coincidence of apply order."
  type        = string
}

variable "addon_name" {
  description = "EKS add-on name, e.g. `vpc-cni`. Must match the name AWS uses; `aws eks describe-addon-versions` lists them."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.addon_name))
    error_message = "addon_name must be a lowercase name such as vpc-cni or aws-ebs-csi-driver."
  }
}

variable "addon_version" {
  description = <<-EOT
    Exact add-on version, e.g. `v1.22.4-eksbuild.3`.

    Required, with no default. Omitting it would let AWS install the current default
    for the cluster's Kubernetes version, which changes over time — so the same
    configuration would produce different software on different days, and the
    difference would look like drift rather than a decision.

    Find the default for a version with:
      aws eks describe-addon-versions --kubernetes-version 1.36 --addon-name vpc-cni
  EOT
  type        = string
  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[a-z0-9.]+)?$", var.addon_version))
    error_message = "addon_version must look like v1.22.4-eksbuild.3 — note the leading v."
  }
}

variable "configuration_values" {
  description = <<-EOT
    Add-on configuration, as a JSON string. AWS validates it against the add-on's own
    schema, so a wrong key is rejected at apply rather than silently ignored.

    For vpc-cni with prefix delegation:
      jsonencode({ env = { ENABLE_PREFIX_DELEGATION = "true" } })
  EOT
  type        = string
  default     = null
  validation {
    condition     = var.configuration_values == null || can(jsondecode(var.configuration_values))
    error_message = "configuration_values must be valid JSON. Use jsonencode() rather than a hand-written string."
  }
}

variable "pod_identity" {
  description = <<-EOT
    IAM role and service account for this add-on, via EKS Pod Identity. Omit entirely
    for add-ons that need no AWS permissions.

    A single object rather than two arguments, so a role without a service account is
    not expressible. That combination is worth making impossible: it creates no
    association, so the add-on falls back to the NODE role's permissions and appears to
    work — with the wrong identity, and no error anywhere.

    `coredns` and `kube-proxy` need nothing here. Ask AWS rather than guessing:
      aws eks describe-addon-configuration --addon-name vpc-cni --addon-version V

    That returns the service account to use and the policy AWS recommends:
      vpc-cni             -> aws-node                / AmazonEKS_CNI_Policy
      aws-ebs-csi-driver  -> ebs-csi-controller-sa   / AmazonEBSCSIDriverPolicyV2
  EOT
  type = object({
    role_arn        = string
    service_account = string
  })
  default = null

  validation {
    condition     = var.pod_identity == null || can(regex("^arn:[a-z-]+:iam::[0-9]{12}:role/", var.pod_identity.role_arn))
    error_message = "pod_identity.role_arn must be a full IAM role ARN. Pass the iam-role module's .arn output."
  }

  validation {
    condition     = var.pod_identity == null || can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.pod_identity.service_account))
    error_message = "pod_identity.service_account must be an RFC 1123 label, and must match the account the add-on actually runs as."
  }
}

variable "resolve_conflicts_on_create" {
  description = "`OVERWRITE` or `NONE`. Defaults to OVERWRITE because EKS pre-installs self-managed vpc-cni, kube-proxy and coredns on every new cluster, so taking over is the normal case."
  type        = string
  default     = "OVERWRITE"
  validation {
    condition     = contains(["OVERWRITE", "NONE"], var.resolve_conflicts_on_create)
    error_message = "resolve_conflicts_on_create must be OVERWRITE or NONE."
  }
}

variable "resolve_conflicts_on_update" {
  description = "`OVERWRITE`, `NONE` or `PRESERVE`. Defaults to OVERWRITE so out-of-band edits are discarded on the next apply rather than persisting untracked."
  type        = string
  default     = "OVERWRITE"
  validation {
    condition     = contains(["OVERWRITE", "NONE", "PRESERVE"], var.resolve_conflicts_on_update)
    error_message = "resolve_conflicts_on_update must be OVERWRITE, NONE or PRESERVE."
  }
}

variable "preserve" {
  description = "Keep the add-on's Kubernetes resources when the add-on is deleted from Terraform. Off by default — an orphaned DaemonSet nothing manages is how a cluster stops matching its configuration."
  type        = bool
  default     = false
}

variable "create_timeout" {
  description = "Timeout for add-on creation. The default is generous because an add-on whose pods cannot schedule waits rather than failing fast, and the useful signal is the timeout message."
  type        = string
  default     = "20m"
}

variable "update_timeout" {
  description = "Timeout for add-on updates."
  type        = string
  default     = "20m"
}

variable "extra_tags" {
  description = "Additional tags. Merged FIRST, so mandatory tags win on a key collision."
  type        = map(string)
  default     = {}
}
