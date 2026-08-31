output "name" {
  description = "Node group name."
  value       = aws_eks_node_group.this.node_group_name
}

output "arn" {
  description = "Node group ARN."
  value       = aws_eks_node_group.this.arn
}

output "status" {
  description = "Node group status. `ACTIVE` once nodes have registered."
  value       = aws_eks_node_group.this.status
}

output "autoscaling_group_names" {
  description = "Underlying autoscaling group names. Needed by anything that manages capacity directly, or to find the instances."
  value       = [for r in aws_eks_node_group.this.resources : r.autoscaling_groups[0].name]
}

# ── The two that exist so a later layer does not restate them ─────────────────

output "labels" {
  description = <<-EOT
    The labels on every node in this pool.

    Propagated so a workload's `nodeSelector` can be derived from what the pool has,
    rather than copied and left to drift.
  EOT
  value       = var.labels
}

output "taints" {
  description = <<-EOT
    The taints on every node in this pool, in the EKS API spelling.

    Propagated for the same reason as labels, and it matters more here: a toleration
    that no longer matches its taint produces a pool nothing can schedule on, and the
    symptom is `Pending` pods with a message nobody reads.
  EOT
  value       = var.taints
}

output "tolerations" {
  description = <<-EOT
    The same taints rendered as Kubernetes toleration objects, ready to drop into a
    pod spec.

    Two spellings exist and they are not interchangeable: the EKS API uses
    `NO_SCHEDULE`, a Kubernetes manifest uses `NoSchedule`. Translating here means the
    conversion happens once, in the place that knows the taint, instead of by hand at
    every workload that needs to tolerate it.
  EOT
  value = [
    for k, t in var.taints : merge(
      {
        key    = t.key
        effect = join("", [for w in split("_", lower(t.effect)) : title(w)])
      },
      t.value == null ? { operator = "Exists" } : { operator = "Equal", value = t.value },
    )
  ]
}

output "inventory" {
  description = "Structured record of this pool, for cross-layer inventory and review."
  value = {
    name           = aws_eks_node_group.this.node_group_name
    cluster_name   = var.cluster_name
    pool           = var.pool
    instance_types = var.instance_types
    capacity_type  = var.capacity_type
    ami_type       = var.ami_type
    disk_size_gib  = var.disk_size

    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size

    labels = var.labels
    taints = var.taints

    # Recorded because a SPOT pool holding anything with a PVC is a recurring mistake:
    # the node is reclaimed with two minutes' notice and the volume is left behind in
    # one availability zone.
    interruptible = var.capacity_type == "SPOT"

    node_role_arn       = var.node_role_arn
    node_repair_enabled = var.enable_node_repair
  }
}
