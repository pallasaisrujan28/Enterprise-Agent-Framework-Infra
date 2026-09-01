output "namespace_names" {
  description = "The namespaces this layer owns, sorted. L3 deploys into these."
  value       = sort([for k, m in module.namespace : m.name])
}

output "storage_class_name" {
  description = "The default StorageClass. A workload puts this in `storageClassName` — or omits it, since this class is the cluster default."
  value       = module.storage_class_gp3.name
}

output "network_policy_state" {
  description = <<-EOT
    Per namespace: `enforced`, `NOT-ENFORCED-no-enforcer-in-cluster`, or `none`.

    The middle value means a default-deny policy was asked for and deliberately not
    created, because nothing in the cluster would act on it. Worth reading after any change
    to the vpc-cni add-on, since that is where enforcement is switched on.
  EOT
  value       = { for k, m in module.namespace : k => m.network_policy_state }
}

output "cluster_addons_inventory" {
  description = "One structured record of this layer, for review without reading the plan."
  value = {
    cluster_name = local.cluster_name

    storage = {
      managed = module.storage_class_gp3.inventory

      # The class EKS created and this layer deliberately does not own. Named here so it
      # appears in review rather than only in the cluster — Property 7 asks that unmanaged
      # objects be accounted for, not that they cannot exist.
      unmanaged_note = join(" ", [
        "gp2 exists in this cluster, created by EKS at cluster creation and owned by no",
        "Terraform state. Left alone deliberately: nothing references it, so it has",
        "provisioned nothing and costs nothing. It is NOT the cluster default.",
      ])
    }

    namespaces = { for k, m in module.namespace : k => m.inventory }

    # The single most misreadable fact about this layer, stated once and plainly.
    ingress_default_deny_effective = alltrue([
      for k, m in module.namespace : m.inventory.ingress_actually_restricted
    ])
  }
}
