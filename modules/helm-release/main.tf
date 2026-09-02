# One Helm release, with the defaults this repository learned the hard way.
#
# WHY A WRAPPER AT ALL, when `helm_release` is already one resource.
#
# Three settings decide whether a failed release is visible, and all three defaulted the
# wrong way in the configuration this replaces: `wait = false`, no bounded timeout, and no
# `atomic`. A release could be created with a failed status while the apply reported success
# — which is how `helm list` came to disagree with what was actually running.
#
# Centralising them means the safe combination is what you get by saying nothing, and a
# deviation is a visible argument at the call site rather than an omission.
#
# It also isolates the provider's v2-to-v3 schema break to one file.

resource "helm_release" "this" {
  name      = var.name
  namespace = var.namespace

  repository = var.repository
  chart      = var.chart
  version    = var.chart_version

  # VALUES AS ONE YAML DOCUMENT, never `set`.
  #
  # `set` stringifies every value and needs `a.b[0].c` paths whose escaping rules collide
  # with Kubernetes keys that contain dots — which is most annotation keys and every Neo4j
  # config key. It is also the surface the provider changed between majors.
  #
  # yamlencode preserves types, so a number stays a number and a bool stays a bool.
  values = [yamlencode(var.values)]

  # False by default. Namespaces belong to the cluster-addons layer, together with the
  # default-deny NetworkPolicy and quota that a Helm-created namespace would not have.
  create_namespace = var.create_namespace

  wait    = var.wait
  timeout = var.timeout_seconds
  atomic  = var.atomic

  recreate_pods = var.recreate_pods

  # `atomic` already implies waiting, but stating both means the plan reads unambiguously
  # and a future change to one does not silently alter the other.
  lifecycle {
    precondition {
      condition     = var.atomic ? var.wait : true
      error_message = "atomic requires wait: a rollback decision cannot be made without waiting to see whether the release became ready."
    }
  }
}
