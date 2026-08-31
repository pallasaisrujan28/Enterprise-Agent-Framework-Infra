# ONE EKS add-on, plus its Pod Identity association if it needs AWS permissions.
#
# One add-on per call, rather than a map of them in a single module. That is
# deliberate: the add-ons do NOT all belong at the same point in the graph, and the
# ordering is a property of the composition rather than of any add-on.
#
#   BEFORE the node group      vpc-cni, kube-proxy, eks-pod-identity-agent
#   AFTER the node group       coredns, aws-ebs-csi-driver
#
# Get it wrong in the first direction and nodes join a cluster with no CNI: they fail
# their health check with `NodeCreationFailure: NetworkPluginNotReady` and sit
# `NotReady`. Get it wrong in the second and the add-on's pods have nowhere to
# schedule, the add-on stays `DEGRADED`, and Terraform waits until it times out.
#
# A single module taking every add-on could not express that split — the after-compute
# ones would need a node-group value as an input, which makes the whole module wait on
# the node group, which waits on the cluster. So each call site states its own
# `depends_on`, where both objects are visible.

locals {
  mandatory_tags = {
    ManagedBy       = "terraform"
    ManagedByModule = "modules/eks-addon"
    OrgPrefix       = var.org_prefix
    Environment     = var.environment
    Owner           = var.owner
    AddonName       = var.addon_name
  }

  tags = merge(var.extra_tags, local.mandatory_tags)

  # Only emitted when a role is supplied. An add-on that needs no AWS permissions —
  # coredns and kube-proxy return no Pod Identity recommendation from
  # describe-addon-configuration — gets no association and needs no role.
  pod_identity = var.pod_identity == null ? [] : [var.pod_identity]
}

resource "aws_eks_addon" "this" {
  cluster_name = var.cluster_name
  addon_name   = var.addon_name

  # Pinned, never left to AWS's default.
  #
  # Omitting addon_version installs whatever is default for the cluster's Kubernetes
  # version at apply time, which changes as AWS ships builds. Two applies from
  # identical configuration would then install different software, and the diff would
  # appear as unexplained drift rather than as a decision.
  addon_version = var.addon_version

  # Configuration is a JSON string, validated by AWS against the add-on's own schema.
  configuration_values = var.configuration_values

  # OVERWRITE on create, because EKS installs self-managed versions of vpc-cni,
  # kube-proxy and coredns on every new cluster. Taking over management of something
  # already running is the normal case here, and the default (NONE) fails with a
  # conflict instead.
  resolve_conflicts_on_create = var.resolve_conflicts_on_create

  # OVERWRITE on update too: it discards field-level changes made outside Terraform,
  # which is the point. An add-on patched by hand during an incident is exactly the
  # untracked change this repository exists to stop.
  resolve_conflicts_on_update = var.resolve_conflicts_on_update

  # Pod Identity rather than IRSA. `service_account_role_arn` is the IRSA form and is
  # deliberately not used — see learnings/005.
  dynamic "pod_identity_association" {
    for_each = local.pod_identity
    content {
      role_arn        = pod_identity_association.value.role_arn
      service_account = pod_identity_association.value.service_account
    }
  }

  # `preserve` keeps the add-on's Kubernetes objects when the add-on is removed from
  # Terraform. Off by default: leaving a running DaemonSet that nothing manages is
  # how you get a cluster whose contents no longer match any configuration.
  preserve = var.preserve

  tags = local.tags

  timeouts {
    create = var.create_timeout
    update = var.update_timeout
  }
}
