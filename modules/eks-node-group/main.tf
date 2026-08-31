# One managed node group.
#
# Called once per pool. Taints and labels are inputs AND outputs: a workload in a
# later layer derives its tolerations and nodeSelector from what this pool actually
# has, rather than restating them and drifting.
#
# ORDERING, which this module cannot enforce and the caller must:
#
#   vpc-cni, kube-proxy and eks-pod-identity-agent must be ACTIVE before this exists.
#   A node that joins a cluster with no CNI fails its health check with
#   `NodeCreationFailure: NetworkPluginNotReady` and stays NotReady. The node group
#   does not fail fast — it waits, then times out.
#
#   coredns and aws-ebs-csi-driver must come AFTER this. Their pods have nowhere to
#   schedule on an empty cluster, so the add-on sits DEGRADED until Terraform gives up.
#
# Expressed with `depends_on` at the call site. It cannot live here: taking an add-on
# value as an input would make this module wait, and taking a node-group value into the
# add-on module would make that wait — the second direction is a cycle.

locals {
  name = "${var.org_prefix}-${var.environment}-${var.pool}"

  mandatory_tags = {
    ManagedBy       = "terraform"
    ManagedByModule = "modules/eks-node-group"
    OrgPrefix       = var.org_prefix
    Environment     = var.environment
    Owner           = var.owner
    Pool            = var.pool
  }

  tags = merge(var.extra_tags, local.mandatory_tags)

  # NOT set: kubernetes.io/cluster/<name>, or the Cluster Autoscaler discovery tags
  # k8s.io/cluster-autoscaler/enabled and k8s.io/cluster-autoscaler/<name>.
  #
  # EKS applies what a managed node group needs itself. The autoscaler tags belong
  # with an autoscaler, and adding them before one exists advertises a pool to a
  # controller that is not running — which reads, to the next person, as if
  # autoscaling were configured.
}

resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = local.name
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids

  instance_types = var.instance_types
  capacity_type  = var.capacity_type
  ami_type       = var.ami_type
  disk_size      = var.disk_size

  # null follows the cluster, which is what you want unless staging an upgrade.
  version = var.kubernetes_version

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  update_config {
    max_unavailable = var.max_unavailable
  }

  labels = var.labels

  dynamic "taint" {
    for_each = var.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  dynamic "node_repair_config" {
    for_each = var.enable_node_repair ? [1] : []
    content {
      enabled = true
    }
  }

  tags = merge(local.tags, { Name = local.name })

  timeouts {
    create = var.create_timeout
  }

  lifecycle {
    # desired_size is intentionally NOT ignored.
    #
    # The usual advice is to ignore it so an autoscaler can move it without Terraform
    # fighting back. There is no autoscaler here yet, so ignoring it would instead
    # mean the number in the configuration silently stops being the number that runs —
    # and the design raises desired_size deliberately as workloads land. Revisit when
    # an autoscaler exists; until then the configuration is the truth.

    precondition {
      condition     = var.desired_size >= var.min_size && var.desired_size <= var.max_size
      error_message = "desired_size (${var.desired_size}) must be between min_size (${var.min_size}) and max_size (${var.max_size})."
    }

    # An ARM AMI on an x86 instance, or the reverse, fails at launch with a message
    # about the image rather than about the mismatch — and the node group waits on
    # instances that will never register before timing out.
    precondition {
      condition = (
        !strcontains(var.ami_type, "ARM_64") ||
        alltrue([for t in var.instance_types : can(regex("^[a-z0-9]*g[a-z0-9]*\\.", t))])
      )
      error_message = "ami_type ${var.ami_type} is ARM, but instance_types (${join(", ", var.instance_types)}) are not all Graviton. AWS ARM instance families carry a 'g' in the size prefix, such as m6g, m7g, c7g or t4g."
    }

    precondition {
      condition = (
        strcontains(var.ami_type, "ARM_64") ||
        alltrue([for t in var.instance_types : !can(regex("^[a-z]+[0-9]+g[a-z]*\\.", t))])
      )
      error_message = "instance_types (${join(", ", var.instance_types)}) include a Graviton (ARM) family, but ami_type ${var.ami_type} is x86. Use AL2023_ARM_64_STANDARD or BOTTLEROCKET_ARM_64."
    }
  }
}
