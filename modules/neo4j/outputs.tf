output "bolt_uri" {
  description = <<-EOT
    Bolt URI for clients. This is the value a consumer puts in `NEO4J_URI`.

    `bolt://` rather than `neo4j://`: the two differ in that `neo4j://` performs routing
    discovery for a cluster, and asking a single-instance Community deployment for a routing
    table produces an error about routing being unavailable rather than a connection.
  EOT
  value       = "bolt://${local.bolt_host}:7687"
}

output "http_uri" {
  description = "HTTP URI for the Neo4j browser. Reachable through `kubectl port-forward`; no Service is exposed beyond the cluster."
  value       = "http://${local.bolt_host}:7474"
}

output "service_host" {
  description = "In-cluster DNS name of the Neo4j service, without scheme or port."
  value       = local.bolt_host
}

output "username" {
  description = "The database user. Fixed at `neo4j` — the chart's NEO4J_AUTH format hardcodes it as the part before the slash."
  value       = "neo4j"
}

output "password_secret_name" {
  description = <<-EOT
    Name of the Secret holding the credential.

    Pass THIS to a consumer, as a `secretKeyRef`, rather than passing the password itself.
    A password threaded through a Terraform output ends up in the consuming layer's state as
    well as this one, doubling the number of places it exists.
  EOT
  value       = kubernetes_secret_v1.auth.metadata[0].name
}

output "password_secret_key" {
  description = "Key within that Secret. `NEO4J_AUTH`, holding `neo4j/<password>` — note it is the pair, not a bare password, so a consumer expecting only a password must split it."
  value       = "NEO4J_AUTH"
}

output "password" {
  description = "The generated password. Marked sensitive; prefer `password_secret_name` so the value is read from the Secret rather than copied between states."
  value       = random_password.neo4j.result
  sensitive   = true
}

output "inventory" {
  description = "Structured record of this deployment, for cross-layer inventory and review."
  value = {
    name          = var.name
    namespace     = var.namespace
    chart_version = module.release.chart_version
    bolt_uri      = "bolt://${local.bolt_host}:7687"
    status        = module.release.status

    storage = {
      class_name = var.storage_class_name
      size       = var.storage_size

      # The honest flag. The gp3 class reclaims on delete, so destroying this module destroys
      # the graph. True is the correct value for a dev environment whose graph is rebuildable;
      # it is stated rather than implied because the consequence is data loss.
      data_is_destroyed_with_this_module = true
    }

    access = {
      # The two properties that decide whether the database is actually protected. Both must
      # hold: authentication stops a network path being sufficient, and an enforced policy
      # stops the network path existing.
      authentication_enabled = true
      policy_enforced        = var.network_policy_enforced

      # False means nothing can reach bolt. A valid state before a consumer exists, and worth
      # surfacing so it is not mistaken for a broken deployment.
      reachable_by_anything = local.create_policy

      allowed_namespaces = sort(distinct(concat(
        var.allowed_client_namespaces,
        var.allow_same_namespace ? [var.namespace] : [],
      )))

      # The default this module overrides, recorded because the consequence of the override
      # being lost is an internet-facing database plus a leaked load balancer.
      # DERIVED from the same local the chart values use, never restated. As two independent
      # literals these could disagree, and the one a test reads is not the one Helm receives
      # — verified by mutation, which flipped the chart value with every test still passing.
      service_type      = local.service_type
      chart_default_was = "LoadBalancer"

      # Both follow from the service type rather than being asserted alongside it.
      internet_reachable    = local.service_type == "LoadBalancer"
      creates_load_balancer = local.service_type == "LoadBalancer"
    }
  }
}
