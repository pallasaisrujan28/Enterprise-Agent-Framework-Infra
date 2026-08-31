output "addon_name" {
  description = "Add-on name."
  value       = aws_eks_addon.this.addon_name
}

output "addon_version" {
  description = "Installed add-on version."
  value       = aws_eks_addon.this.addon_version
}

output "arn" {
  description = "Add-on ARN."
  value       = aws_eks_addon.this.arn
}

output "id" {
  description = <<-EOT
    Composite id, `cluster:addon`.

    Useful as a `depends_on` target: an add-on that must exist before something else
    can work — the CNI before nodes join — is expressed by depending on this rather
    than by hoping apply order happens to be right.
  EOT
  value       = aws_eks_addon.this.id
}

output "inventory" {
  description = "Structured record of this add-on, for cross-layer inventory and review."
  value = {
    cluster_name  = var.cluster_name
    addon_name    = aws_eks_addon.this.addon_name
    addon_version = aws_eks_addon.this.addon_version

    # How this add-on gets AWS permissions, if it does. Reported plainly because the
    # alternative — silently falling back to the node role — looks identical from
    # outside until you ask which credentials a pod is actually using.
    identity = var.pod_identity == null ? "none: this add-on needs no AWS permissions" : format(
      "pod-identity: %s as %s", var.pod_identity.role_arn, var.pod_identity.service_account,
    )

    configuration        = var.configuration_values
    resolve_on_create    = var.resolve_conflicts_on_create
    resolve_on_update    = var.resolve_conflicts_on_update
    preserve_on_delete   = var.preserve
    prefix_delegation_on = try(jsondecode(var.configuration_values).env.ENABLE_PREFIX_DELEGATION, null) == "true"
  }
}
