output "neo4j_bolt_uri" {
  description = "Bolt URI for the graph. This is the value a consumer puts in NEO4J_URI."
  value       = module.neo4j.bolt_uri
}

output "neo4j_secret_name" {
  description = <<-EOT
    Name of the Kubernetes Secret holding the Neo4j credential, in the memory namespace.

    Consumers reference this with a `secretKeyRef` rather than receiving the password. A
    password passed between layers exists in both layers' state, which doubles the number of
    places it has to be protected.

    Read it for a `cypher-shell` session with:
      kubectl -n memory get secret <name> -o jsonpath='{.data.NEO4J_AUTH}' | base64 -d
    The value is `neo4j/<password>`, the pair rather than a bare password.
  EOT
  value       = module.neo4j.password_secret_name
}

output "neo4j_username" {
  description = "The database user. Fixed at `neo4j` by the chart's NEO4J_AUTH format."
  value       = module.neo4j.username
}

output "port_forward_command" {
  description = "Open the Neo4j browser locally. No Service is exposed beyond the cluster, so this is the access path."
  value       = "kubectl -n ${var.memory_namespace} port-forward svc/${module.neo4j.inventory.name} 7474:7474 7687:7687"
}

output "apps_inventory" {
  description = "One structured record of this layer, for review without reading the plan."
  value = {
    cluster_name = local.cluster_name
    namespace    = var.memory_namespace

    neo4j = module.neo4j.inventory

    # What this layer relies on other layers for. Recorded because a value read from another
    # layer's state is a dependency, and an undocumented dependency is how apply order
    # becomes folklore.
    consumed_from_other_layers = {
      cluster_name_from       = "workloads/dev/platform"
      storage_class_from      = "workloads/dev/cluster-addons"
      storage_class_name      = local.storage_class_name
      namespace_from          = "workloads/dev/cluster-addons"
      network_policy_state    = local.network_policy_state
      network_policy_enforced = local.network_policy_enforced
    }

    # The teardown consequence, stated rather than implied. `scripts/teardown_guard.py`
    # refuses to destroy the platform layer while this one still holds resources, which is
    # what keeps the volume from being leaked rather than deleted.
    teardown = {
      destroying_this_layer_destroys_the_graph = true
      must_be_destroyed_before                 = "workloads/dev/cluster-addons, then workloads/dev/platform"
    }
  }
}
