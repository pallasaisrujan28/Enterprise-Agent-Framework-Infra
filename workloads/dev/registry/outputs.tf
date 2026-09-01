output "repository_urls" {
  description = <<-EOT
    Repository URLs, keyed by name.

    Consumed by whatever builds and pushes images — including the APPLICATION repository's
    workflow, which needs `eaf/agent`. Pass this rather than reconstructing
    `<account>.dkr.ecr.<region>.amazonaws.com/<name>`: a reconstructed string creates no
    dependency edge, so a change here breaks the consumer silently at apply.

    Read by the apps layer through `terraform_remote_state`, which is what keeps a
    workload's image reference tied to a registry that actually exists.
  EOT
  value       = { for k, m in module.ecr : k => m.repository_url }
}

output "repository_arns" {
  description = "Repository ARNs, keyed by name. For an IAM policy that grants push or pull on one repository rather than all of them."
  value       = { for k, m in module.ecr : k => m.arn }
}

output "registry_id" {
  description = "The account hosting the registry. Needed by `aws ecr get-login-password` before a push."
  value       = one(distinct([for k, m in module.ecr : m.registry_id]))
}

output "registry_inventory" {
  description = "One structured record of this layer, for review without reading the plan."
  value = {
    account_id = var.account_id
    region     = var.region

    repositories = { for k, m in module.ecr : k => m.inventory }

    # One boolean for the property a trustworthy rollback depends on: every repository
    # refuses to move an existing tag, so a deployed reference means exactly one image
    # forever.
    all_image_tags_immutable = alltrue([for k, m in module.ecr : m.inventory.tags_are_immutable])

    # And one for the property that decides whether a destroy of this layer would discard
    # images. False is correct here — the layer exists so its contents outlive the cluster.
    destroyable_with_images = anytrue([for k, m in module.ecr : m.inventory.destroyable_with_images])
  }
}
