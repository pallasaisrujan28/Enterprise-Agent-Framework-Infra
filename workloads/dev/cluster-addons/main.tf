# ── Storage ───────────────────────────────────────────────────────────────────
#
# The cluster arrives with a `gp2` StorageClass that EKS creates itself. It is left alone
# and unmanaged, deliberately:
#
#   - no PersistentVolumeClaim references it, so it has provisioned nothing and costs
#     nothing. It is an unused recipe.
#   - deleting it invites EKS to recreate it.
#   - adopting it into this state would mean owning a resource we do not want.
#
# Recorded as a known unmanaged object rather than pretended away. See learnings/006.
#
# What that class WOULD give a workload, if anything used it: the deprecated in-tree
# provisioner reached through Kubernetes' automatic CSI-migration translation, no volume
# expansion, gp2 pricing at 0.1160 USD/GB-month against gp3's 0.0928, and 3 baseline IOPS
# per GB against gp3's flat 3000. It is also not the cluster default — AWS stopped adding
# that annotation at EKS 1.30 — so a chart omitting `storageClassName` currently produces
# a PVC that waits forever.
#
# This is the class that fixes that.

module "storage_class_gp3" {
  source = "../../../modules/k8s-storage-class"

  name = var.storage_class_name

  # The CSI driver by name. Not `kubernetes.io/aws-ebs`, so there is no translation layer
  # between what the configuration says and what runs.
  provisioner = "ebs.csi.aws.com"

  parameters = merge(
    {
      type = "gp3"

      # Strings, because the Kubernetes API takes a map of strings. A bare `true` here is
      # a type error, not a boolean.
      encrypted = var.storage_encrypted ? "true" : "false"
    },
    var.storage_kms_key_id == null ? {} : { kmsKeyId = var.storage_kms_key_id },
  )

  # The cluster has no default today, so this takes the role rather than competing for it.
  is_default = true

  # A full disk becomes a resize rather than provision-copy-switch.
  allow_volume_expansion = true

  # An EBS volume lives in one availability zone. Creating it before the pod is scheduled
  # pins the scheduler to that zone, and a pod it cannot place there stays Pending with an
  # error about node affinity rather than storage.
  volume_binding_mode = "WaitForFirstConsumer"

  # Delete: the volume goes when its claim goes. Right for a disposable environment, and
  # it avoids accumulating volumes nothing tracks. `make storage-orphans` exists because
  # the alternative leaves some behind.
  reclaim_policy = "Delete"

  labels = {
    "eaf.io/layer" = "cluster-addons"
  }
}

# ── Namespaces ────────────────────────────────────────────────────────────────
#
# One module call per namespace, keyed by name so a namespace added or removed does not
# disturb the others' resource addresses.

module "namespace" {
  source   = "../../../modules/k8s-namespace"
  for_each = var.namespaces

  name = each.key

  # Kubernetes' default is that every pod can reach every other pod in the cluster,
  # across namespaces. Without this, Firecrawl's headless browser can open a connection
  # to Neo4j's bolt port.
  default_deny_ingress = true

  # Asserted, not assumed. When false the module creates no policy and labels the
  # namespace to say so, rather than leaving an object that looks like protection and
  # is not.
  network_policy_enforced = var.network_policy_enforced

  resource_quota = each.value.resource_quota
  limit_range    = each.value.limit_range

  labels = {
    "eaf.io/layer" = "cluster-addons"
  }
}
