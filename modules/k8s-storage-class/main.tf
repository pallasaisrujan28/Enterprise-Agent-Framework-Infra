# One StorageClass — the recipe a PersistentVolumeClaim names when it asks for a disk.
#
# A StorageClass creates nothing and costs nothing. It is a template. The volume is
# created later, by the CSI driver's controller pod, when a workload submits a claim
# against it. See learnings/006.

locals {
  # `storageclass.kubernetes.io/is-default-class` is the annotation Kubernetes reads.
  # Written as a string because annotations are strings — a bare `true` is a type error
  # here, not a boolean.
  default_annotation = var.is_default ? {
    "storageclass.kubernetes.io/is-default-class" = "true"
  } : {}
}

resource "kubernetes_storage_class_v1" "this" {
  metadata {
    name        = var.name
    annotations = local.default_annotation

    labels = merge(var.labels, {
      "app.kubernetes.io/managed-by" = "terraform"
      "eaf.io/module"                = "k8s-storage-class"
    })
  }

  storage_provisioner = var.provisioner
  parameters          = var.parameters

  allow_volume_expansion = var.allow_volume_expansion
  reclaim_policy         = var.reclaim_policy
  volume_binding_mode    = var.volume_binding_mode
  mount_options          = var.mount_options

  lifecycle {
    # Almost every field of a StorageClass is immutable. The Kubernetes API rejects an
    # update to the provisioner or parameters, and Terraform's answer is to replace —
    # which is fine, because a StorageClass holds no data. Existing PersistentVolumes
    # keep working: a PV records the parameters it was created with and does not consult
    # the class again.
    #
    # Stated because "replacing the StorageClass" sounds alarming and is not.

    precondition {
      condition = (
        var.volume_binding_mode == "WaitForFirstConsumer" ||
        !can(regex("(ebs|disk)\\.csi", var.provisioner))
      )
      error_message = join(" ", [
        "StorageClass ${var.name} uses a block-storage provisioner (${var.provisioner})",
        "with volume_binding_mode = Immediate. A block volume exists in one availability",
        "zone, so creating it before the pod is scheduled constrains the scheduler to that",
        "zone — and a pod that cannot be placed there stays Pending with an error about",
        "node affinity rather than about storage. Use WaitForFirstConsumer, or set it",
        "deliberately for a provisioner that is not zonal.",
      ])
    }
  }
}
