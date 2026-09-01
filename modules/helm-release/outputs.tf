output "name" {
  description = "Release name, read from the resource so anything referencing it waits for the release to exist."
  value       = helm_release.this.name
}

output "namespace" {
  description = "Namespace the release was installed into."
  value       = helm_release.this.namespace
}

output "chart_version" {
  description = "Exact chart version installed. Worth surfacing: this is the value that makes the deployment reproducible."
  value       = helm_release.this.version
}

output "status" {
  description = "Release status as Helm reports it. `deployed` is the only value that means the release is healthy."
  value       = helm_release.this.status
}

output "inventory" {
  description = "Structured record of this release, for cross-layer inventory and review."
  value = {
    name          = helm_release.this.name
    namespace     = helm_release.this.namespace
    chart         = var.chart
    chart_version = helm_release.this.version
    status        = helm_release.this.status

    # The property that decides whether a failed release can be reported as a successful
    # apply. False here is how a broken release becomes invisible.
    failure_is_visible = var.wait

    # And whether a failure leaves something installed behind.
    rolls_back_on_failure = var.atomic

    timeout_seconds = var.timeout_seconds
  }
}

output "rendered_values" {
  description = <<-EOT
    The exact YAML document handed to Helm.

    EXISTS SO A TEST CAN ASSERT ON WHAT THE CHART ACTUALLY RECEIVES, rather than on a
    caller's description of it. Without this the only thing a calling module can check is its
    own inventory output — and an inventory is a string a human wrote, so a test reading it
    proves the string exists, not that the chart was configured that way. The two can drift
    apart silently, which is how a `ClusterIP` claim survives a change to `LoadBalancer`.

    Sensitive because chart values are a plausible place for a credential, and this would
    otherwise print in full in every plan. Test assertions can still read it.
  EOT
  value       = helm_release.this.values[0]
  sensitive   = true
}
