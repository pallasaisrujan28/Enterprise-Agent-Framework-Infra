variable "name" {
  description = "StorageClass name. This is the string a PersistentVolumeClaim asks for, so it is part of the platform's contract with workloads."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be an RFC 1123 label: lowercase alphanumeric or '-', starting and ending alphanumeric."
  }
}

variable "provisioner" {
  description = <<-EOT
    The CSI driver that makes the volume, e.g. `ebs.csi.aws.com`.

    Use a CSI driver name, not a legacy in-tree name like `kubernetes.io/aws-ebs`. The
    in-tree plugins are deprecated and unregistered on current nodes; a StorageClass
    naming one works only through Kubernetes' automatic CSI-migration translation, which
    means the name in the configuration and the code that runs are different things.
  EOT
  type        = string
  validation {
    condition     = !startswith(var.provisioner, "kubernetes.io/")
    error_message = "kubernetes.io/* provisioners are the deprecated in-tree plugins. Use a CSI driver name such as ebs.csi.aws.com."
  }
}

variable "parameters" {
  description = <<-EOT
    Driver-specific options. For the EBS CSI driver:

      type       gp3 | gp2 | io1 | io2 | sc1 | st1
      encrypted  "true" to encrypt at rest
      kmsKeyId   a CMK, otherwise the AWS-managed EBS key
      fsType     ext4 | xfs

    Values must be strings — the Kubernetes API takes a map of strings, so numbers and
    booleans have to be quoted.
  EOT
  type        = map(string)
  default     = {}
}

variable "is_default" {
  description = <<-EOT
    Mark this class as the cluster default, used by any PVC that names no class.

    Worth a cluster having exactly one. With none, a chart that omits
    `storageClassName` produces a PVC that stays `Pending` forever, and nothing in its
    events says the cluster has no default. With two, Kubernetes 1.26 and later use the
    most recently created — defined behaviour, but a poor thing to depend on.
  EOT
  type        = bool
  default     = false
}

variable "allow_volume_expansion" {
  description = <<-EOT
    Whether a PersistentVolumeClaim bound to this class can be grown later.

    Defaults to true. When false, a full volume can only be replaced: provision a new
    one, copy the data, switch the workload over. For a database that is downtime.
  EOT
  type        = bool
  default     = true
}

variable "volume_binding_mode" {
  description = <<-EOT
    `WaitForFirstConsumer` or `Immediate`.

    Defaults to WaitForFirstConsumer, and for block storage that is close to mandatory.
    An EBS volume exists in ONE availability zone and attaches only to an instance in
    that zone. Binding immediately creates the volume before the pod is scheduled, so
    the scheduler is then constrained to that zone — and if it cannot place the pod
    there, the pod stays Pending with a message about node affinity rather than storage.

    `Immediate` is correct for storage that is not zonal, such as EFS.
  EOT
  type        = string
  default     = "WaitForFirstConsumer"
  validation {
    condition     = contains(["WaitForFirstConsumer", "Immediate"], var.volume_binding_mode)
    error_message = "volume_binding_mode must be WaitForFirstConsumer or Immediate."
  }
}

variable "reclaim_policy" {
  description = <<-EOT
    What happens to the volume when its claim is deleted. `Delete` or `Retain`.

    `Delete` is the default and is right for a disposable environment. `Retain` leaves
    the EBS volume behind — which preserves data through an accident, and also produces
    volumes nobody is tracking and everyone is billed for. `make storage-orphans` exists
    because of that second effect.
  EOT
  type        = string
  default     = "Delete"
  validation {
    condition     = contains(["Delete", "Retain"], var.reclaim_policy)
    error_message = "reclaim_policy must be Delete or Retain."
  }
}

variable "mount_options" {
  description = "Mount options passed to the filesystem, e.g. `[\"noatime\"]`. Rarely needed."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels applied to the StorageClass. Used to record what manages it."
  type        = map(string)
  default     = {}
}
