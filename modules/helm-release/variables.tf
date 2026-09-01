variable "name" {
  description = "Release name. Becomes part of the name of nearly every object the chart creates, so it is not cosmetic."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be a lowercase RFC 1123 label: letters, digits and hyphens, starting and ending alphanumeric."
  }
}

variable "namespace" {
  description = "Namespace to install into. Must already exist — see create_namespace."
  type        = string
}

variable "repository" {
  description = "Chart repository URL. Null for a chart given as a local path or an OCI reference."
  type        = string
  default     = null
}

variable "chart" {
  description = "Chart name within the repository, or a local path, or an `oci://` reference."
  type        = string
}

variable "chart_version" {
  description = <<-EOT
    Exact chart version. REQUIRED, with no default.

    An unpinned chart is an unpinned dependency: the repository's `index.yaml` is mutable, so
    "latest" resolves to whatever was published most recently and two applies of identical
    Terraform can install different software. That is the same class of defect as an image
    tag of `latest`, and Property 5 exists because of it.

    A range is no better here. Helm resolves it at install time, not at plan time, so the
    plan a reviewer approved would not name the version that gets installed.
  EOT
  type        = string
  validation {
    condition     = length(trimspace(var.chart_version)) > 0
    error_message = "chart_version must be an exact version. An empty string resolves to the newest published chart, which is not reproducible."
  }
}

variable "values" {
  description = <<-EOT
    Chart values, as a single object. Rendered to YAML by the module.

    ONE OBJECT RATHER THAN A LIST OF `set` BLOCKS, for two reasons.

    `set` coerces everything to a string, so `replicas = 1` arrives as `"1"` and a chart
    that does arithmetic on it fails in a template rather than at plan time. Nested and list
    values need `a.b[0].c` path syntax, which has its own escaping rules for keys that
    contain dots — and Kubernetes annotation keys nearly always contain dots.

    `set` is also the exact surface the helm provider changed between v2 and v3, from a
    nested block to a typed attribute. Passing values as YAML means this module has no
    opinion on that change.
  EOT
  type        = any
  default     = {}
}

variable "wait" {
  description = <<-EOT
    Block until the release's resources report ready.

    ON by default, against what this repository did before. The previous configuration set
    `wait = false` and `wait_for_rollout = false` to stop Helm blocking an apply that shared
    one state file with everything else. It worked, and it moved the health check from
    "inside the apply" to nowhere: a release could be created with a failed status and the
    apply would report success.

    The fix for a slow apply is a layer boundary, which now exists, not a disabled check.
  EOT
  type        = bool
  default     = true
}

variable "timeout_seconds" {
  description = <<-EOT
    How long to wait for readiness before failing.

    Bounded on purpose. Helm's own default is 300s; a stateful chart that has to provision a
    volume and start a database routinely needs more, and the failure mode of too short a
    timeout is a rollback of something that was about to succeed.
  EOT
  type        = number
  default     = 600
  validation {
    condition     = var.timeout_seconds > 0 && var.timeout_seconds <= 3600
    error_message = "timeout_seconds must be between 1 and 3600. An unbounded wait is a hung pipeline with no diagnostic."
  }
}

variable "atomic" {
  description = <<-EOT
    Roll the release back if it fails to become ready.

    On by default: the alternative is a failed release left installed, which is the state
    that made `helm list` disagree with reality in this repository before.

    What it does NOT do is delete data. A StatefulSet's PersistentVolumeClaims are created
    from a `volumeClaimTemplate` and Kubernetes deliberately does not garbage-collect them
    when the StatefulSet goes away, so an atomic rollback leaves the volume intact.
  EOT
  type        = bool
  default     = true
}

variable "create_namespace" {
  description = <<-EOT
    Let Helm create the namespace.

    FALSE by default, and that is a deliberate boundary rather than a nicety. Namespaces in
    this platform are owned by the cluster-addons layer, which also attaches the default-deny
    NetworkPolicy, the quota and the LimitRange. A namespace created by Helm here would have
    none of those, and would look identical in `kubectl get ns`.
  EOT
  type        = bool
  default     = false
}

variable "recreate_pods" {
  description = "Force a restart of the chart's pods on upgrade. Off by default: it is a blunt instrument that causes downtime, and a changed pod template already triggers a rollout."
  type        = bool
  default     = false
}
