variable "name" {
  description = "Namespace name."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be an RFC 1123 label: lowercase alphanumeric or '-', starting and ending alphanumeric."
  }
  validation {
    condition     = !startswith(var.name, "kube-")
    error_message = "kube-* namespaces belong to Kubernetes. Creating one here would fight the control plane for ownership."
  }
}

variable "default_deny_ingress" {
  description = <<-EOT
    Install a NetworkPolicy that denies all ingress to every pod in this namespace,
    unless a more specific policy allows it.

    Defaults to true. Kubernetes' own default is the opposite — every pod can reach every
    other pod in the cluster, across all namespaces — so without this, Firecrawl's
    headless browser can open a connection to Neo4j's bolt port.

    NetworkPolicies are ADDITIVE: this denies by default, and any other policy selecting
    the same pods adds permission back. So this is a floor, not a wall.

    REQUIRES A NETWORK POLICY ENFORCER. See the note on `network_policy_enforced`.
  EOT
  type        = bool
  default     = true
}

variable "network_policy_enforced" {
  description = <<-EOT
    Assert that something in this cluster actually enforces NetworkPolicy.

    THIS IS THE TRAP. A NetworkPolicy is an object the API server happily stores whether
    or not anything acts on it. With no enforcer, `kubectl get networkpolicy` shows your
    default-deny rule, `kubectl describe` shows it selecting every pod, and traffic flows
    exactly as before. It looks configured and is not.

    The Amazon VPC CNI enforces NetworkPolicy only when `enableNetworkPolicy` is set to
    "true" in its configuration — it is OFF by default. Set this to false while that is
    the case, and the module labels the namespace accordingly rather than creating a
    policy that quietly does nothing.
  EOT
  type        = bool
  default     = false
}

variable "resource_quota" {
  description = <<-EOT
    Optional quota for the namespace, as a map of Kubernetes quota keys to values, e.g.

      { "requests.cpu" = "4", "requests.memory" = "8Gi", "persistentvolumeclaims" = "10" }

    Omit for no quota. A `persistentvolumeclaims` limit is worth considering: it is the
    one resource here whose overuse produces an AWS bill rather than a Pending pod.
  EOT
  type        = map(string)
  default     = null
}

variable "limit_range" {
  description = <<-EOT
    Optional default resource requests and limits for containers that declare none.

      { default_request_cpu = "100m", default_request_memory = "128Mi",
        default_limit_cpu = "1", default_limit_memory = "1Gi" }

    Worth setting where a quota is set: a container with NO request counts as zero against
    the quota but still consumes real capacity on a node, which makes the quota a poor
    description of what is actually running.
  EOT
  type = object({
    default_request_cpu    = optional(string)
    default_request_memory = optional(string)
    default_limit_cpu      = optional(string)
    default_limit_memory   = optional(string)
  })
  default = null
}

variable "labels" {
  description = "Extra labels for the namespace. Merged first, so the module's own labels win on collision."
  type        = map(string)
  default     = {}
}

variable "annotations" {
  description = "Annotations for the namespace."
  type        = map(string)
  default     = {}
}
