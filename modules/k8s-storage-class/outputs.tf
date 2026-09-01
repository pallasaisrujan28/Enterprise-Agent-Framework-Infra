output "name" {
  description = "StorageClass name. This is the value a workload puts in `storageClassName`."
  value       = kubernetes_storage_class_v1.this.metadata[0].name
}

output "is_default" {
  description = "Whether this class is the cluster default."
  value       = var.is_default
}

output "inventory" {
  description = "Structured record of this StorageClass, for cross-layer inventory and review."
  value = {
    name        = kubernetes_storage_class_v1.this.metadata[0].name
    provisioner = var.provisioner
    parameters  = var.parameters
    is_default  = var.is_default

    allow_volume_expansion = var.allow_volume_expansion
    volume_binding_mode    = var.volume_binding_mode
    reclaim_policy         = var.reclaim_policy

    # Surfaced because it is the setting whose consequence is a bill rather than an
    # error: Retain leaves the EBS volume behind when the claim is deleted, and nothing
    # then tracks it. `make storage-orphans` finds those.
    volumes_outlive_their_claims = var.reclaim_policy == "Retain"

    # Encryption is a parameter rather than a field, so it is easy to omit and hard to
    # notice. Reported explicitly.
    encrypted_at_rest = try(var.parameters.encrypted, "false") == "true"
  }
}
