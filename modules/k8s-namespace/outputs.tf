output "name" {
  description = "Namespace name. Pass as an attribute reference so anything deployed into it waits for it to exist."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "network_policy_state" {
  description = <<-EOT
    One of `enforced`, `NOT-ENFORCED-no-enforcer-in-cluster`, or `none`.

    The middle value is the one worth watching for: a default-deny policy was asked for
    and deliberately NOT created, because nothing in the cluster would act on it.
  EOT
  value       = local.policy_state
}

output "inventory" {
  description = "Structured record of this namespace, for cross-layer inventory and review."
  value = {
    name = kubernetes_namespace_v1.this.metadata[0].name

    default_deny_ingress_requested = var.default_deny_ingress
    default_deny_ingress_created   = local.create_policy
    network_policy_state           = local.policy_state

    # The honest summary. `true` only when a policy exists AND something enforces it —
    # so this cannot read as protected when it is not.
    ingress_actually_restricted = local.create_policy

    resource_quota = var.resource_quota
    limit_range    = var.limit_range
  }
}
