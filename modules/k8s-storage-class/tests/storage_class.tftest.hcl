# Unit tests for modules/k8s-storage-class.
#
# command = plan, mocked provider, no cluster and no credentials.
# Verified to pass with every AWS and KUBE environment variable unset.

mock_provider "kubernetes" {}

variables {
  name        = "gp3"
  provisioner = "ebs.csi.aws.com"
  parameters  = { type = "gp3", encrypted = "true" }
}

run "defaults_are_the_ones_that_avoid_a_stuck_pvc" {
  command = plan

  # WaitForFirstConsumer, because an EBS volume lives in one availability zone. Binding
  # immediately creates the volume first and then constrains the scheduler to that zone —
  # and a pod it cannot place there stays Pending with a message about node affinity
  # rather than about storage.
  assert {
    condition     = kubernetes_storage_class_v1.this.volume_binding_mode == "WaitForFirstConsumer"
    error_message = "volume_binding_mode should default to WaitForFirstConsumer for block storage."
  }

  # A full volume should be a resize, not provision-copy-switch.
  assert {
    condition     = kubernetes_storage_class_v1.this.allow_volume_expansion == true
    error_message = "allow_volume_expansion should default to true."
  }

  assert {
    condition     = kubernetes_storage_class_v1.this.reclaim_policy == "Delete"
    error_message = "reclaim_policy should default to Delete so volumes do not outlive their claims untracked."
  }
}

run "not_default_unless_asked" {
  command = plan

  # A cluster wants exactly one default. The module must not assume it is the one.
  assert {
    condition = (
      lookup(kubernetes_storage_class_v1.this.metadata[0].annotations, "storageclass.kubernetes.io/is-default-class", null) == null
    )
    error_message = "the default-class annotation must be absent unless is_default is set."
  }
}

run "default_annotation_is_the_string_true" {
  command = plan

  variables {
    is_default = true
  }

  # Annotations are strings. A bare boolean is a type error, and the annotation is only
  # honoured when the VALUE is "true" — an annotation set to "false" is not the same as
  # absent, but it is also not default.
  assert {
    condition = (
      kubernetes_storage_class_v1.this.metadata[0].annotations["storageclass.kubernetes.io/is-default-class"] == "true"
    )
    error_message = "the default-class annotation must be the string \"true\"."
  }
}

run "reject_the_deprecated_in_tree_provisioner" {
  command = plan

  variables {
    # This is what EKS's own gp2 class uses. It works only through Kubernetes'
    # automatic CSI-migration translation, so the name in the configuration and the code
    # that runs are different things. Not something to author deliberately.
    provisioner = "kubernetes.io/aws-ebs"
  }

  expect_failures = [var.provisioner]
}

run "reject_immediate_binding_for_block_storage" {
  command = plan

  variables {
    volume_binding_mode = "Immediate"
  }

  # Caught by a resource precondition rather than a variable validation, because it
  # depends on the provisioner as well as the mode.
  expect_failures = [kubernetes_storage_class_v1.this]
}

run "immediate_binding_is_allowed_for_non_zonal_storage" {
  command = plan

  variables {
    provisioner         = "efs.csi.aws.com"
    volume_binding_mode = "Immediate"
    parameters          = {}
  }

  # EFS is not zone-bound, so Immediate is correct there. The guard must not be a blanket
  # ban — a rule that fires on the wrong cases gets worked around rather than heeded.
  assert {
    condition     = kubernetes_storage_class_v1.this.volume_binding_mode == "Immediate"
    error_message = "Immediate binding should be allowed for a provisioner that is not zonal."
  }
}

run "reject_bad_name" {
  command = plan

  variables {
    name = "GP3_Fast"
  }

  expect_failures = [var.name]
}

# ── Inventory ────────────────────────────────────────────────────────────────

run "inventory_reports_encryption_and_retention" {
  command = plan

  assert {
    condition     = output.inventory.encrypted_at_rest == true
    error_message = "encryption is a parameter rather than a field, so it must be reported explicitly."
  }

  assert {
    condition     = output.inventory.volumes_outlive_their_claims == false
    error_message = "with reclaim_policy Delete, volumes should not be reported as outliving their claims."
  }
}

run "inventory_flags_retain_because_the_cost_is_silent" {
  command = plan

  variables {
    reclaim_policy = "Retain"
  }

  # Retain preserves data through an accident and also leaves EBS volumes that nothing
  # tracks and everyone is billed for. The second effect is why this is surfaced.
  assert {
    condition     = output.inventory.volumes_outlive_their_claims == true
    error_message = "Retain must be reported: it leaves volumes behind when a claim is deleted."
  }
}

run "inventory_reports_unencrypted_when_not_set" {
  command = plan

  variables {
    parameters = { type = "gp3" }
  }

  assert {
    condition     = output.inventory.encrypted_at_rest == false
    error_message = "omitting the encrypted parameter must report as not encrypted, not as unknown."
  }
}
