# Unit tests for modules/eks-node-group.
#
# command = plan throughout. No credentials.
# Verified to pass with every AWS environment variable unset.

mock_provider "aws" {}

variables {
  org_prefix    = "eaf"
  environment   = "dev"
  owner         = "platform-team"
  pool          = "default"
  cluster_name  = "eaf-dev"
  node_role_arn = "arn:aws:iam::718438899462:role/eaf-dev-platform-eks-node-role"
  subnet_ids    = ["subnet-aaa", "subnet-bbb"]

  instance_types = ["m6i.large"]
  desired_size   = 2
  min_size       = 1
  max_size       = 4
}

run "names_include_org_environment_and_pool" {
  command = plan

  assert {
    condition     = aws_eks_node_group.this.node_group_name == "eaf-dev-default"
    error_message = "expected eaf-dev-default, got ${aws_eks_node_group.this.node_group_name}"
  }
}

run "defaults_are_the_safe_ones" {
  command = plan

  assert {
    condition     = aws_eks_node_group.this.capacity_type == "ON_DEMAND"
    error_message = "capacity_type should default to ON_DEMAND; SPOT nodes are reclaimed with two minutes' notice."
  }

  # Amazon Linux 2 is end of life.
  assert {
    condition     = aws_eks_node_group.this.ami_type == "AL2023_x86_64_STANDARD"
    error_message = "ami_type should default to AL2023, not the end-of-life AL2."
  }

  # 20 GiB is the AWS default and is tight once a few container images are cached.
  assert {
    condition     = aws_eks_node_group.this.disk_size >= 50
    error_message = "disk_size should default to something larger than the AWS default of 20 GiB."
  }

  # kubernetes_version defaults to null so nodes follow the cluster. Asserted on the
  # variable rather than the resource: when the argument is unset AWS fills it in, so
  # the resource attribute is unknown at plan and cannot be compared.
  assert {
    condition     = var.kubernetes_version == null
    error_message = "kubernetes_version should default to null so nodes follow the cluster."
  }

  assert {
    condition     = one(aws_eks_node_group.this.update_config).max_unavailable == 1
    error_message = "max_unavailable should default to 1."
  }
}

run "explicit_kubernetes_version_reaches_the_resource" {
  command = plan

  variables {
    kubernetes_version = "1.35"
  }

  # The pass-through path, for staging a node upgrade behind the control plane.
  assert {
    condition     = aws_eks_node_group.this.version == "1.35"
    error_message = "an explicit kubernetes_version should reach the node group."
  }
}

run "reject_patch_version_on_nodes" {
  command = plan

  variables {
    kubernetes_version = "1.36.2"
  }

  expect_failures = [var.kubernetes_version]
}

run "obsolete_and_premature_tags_are_not_set" {
  command = plan

  # EKS applies what a managed node group needs itself.
  assert {
    condition     = !contains(keys(aws_eks_node_group.this.tags), "kubernetes.io/cluster/eaf-dev")
    error_message = "the kubernetes.io/cluster tag is applied by EKS and should not be set here."
  }

  # Advertising a pool to an autoscaler that is not running reads, to the next person,
  # as though autoscaling were configured.
  assert {
    condition = !anytrue([
      for k in keys(aws_eks_node_group.this.tags) : startswith(k, "k8s.io/cluster-autoscaler/")
    ])
    error_message = "cluster-autoscaler discovery tags should not be set before an autoscaler exists."
  }
}

# ── Taints and tolerations ───────────────────────────────────────────────────

run "taints_are_applied_and_translated_for_workloads" {
  command = plan

  variables {
    pool = "memory"
    taints = {
      dedicated = {
        key    = "workload"
        value  = "memory"
        effect = "NO_SCHEDULE"
      }
    }
  }

  assert {
    condition     = one(aws_eks_node_group.this.taint).effect == "NO_SCHEDULE"
    error_message = "the EKS API spelling NO_SCHEDULE should reach the resource."
  }

  # The two spellings are not interchangeable: the EKS API uses NO_SCHEDULE, a
  # Kubernetes manifest uses NoSchedule. Translating here means the conversion happens
  # once, in the place that knows the taint, rather than by hand at every workload.
  assert {
    condition     = one(output.tolerations).effect == "NoSchedule"
    error_message = "toleration effect should be the Kubernetes spelling NoSchedule, got ${one(output.tolerations).effect}"
  }

  assert {
    condition = (
      one(output.tolerations).operator == "Equal" &&
      one(output.tolerations).value == "memory" &&
      one(output.tolerations).key == "workload"
    )
    error_message = "a taint with a value should produce an Equal toleration carrying it."
  }
}

run "valueless_taint_produces_an_exists_toleration" {
  command = plan

  variables {
    taints = {
      dedicated = {
        key    = "workload"
        effect = "NO_EXECUTE"
      }
    }
  }

  # Equal with no value never matches; Exists is the correct operator.
  assert {
    condition = (
      one(output.tolerations).operator == "Exists" &&
      one(output.tolerations).effect == "NoExecute"
    )
    error_message = "a taint with no value must produce an Exists toleration, not Equal with a null value."
  }
}

run "labels_and_taints_are_propagated_for_later_layers" {
  command = plan

  variables {
    labels = { "eaf.io/pool" = "default" }
  }

  assert {
    condition     = output.labels["eaf.io/pool"] == "default"
    error_message = "labels should be output so a nodeSelector can be derived rather than restated."
  }
}

run "reject_kubernetes_manifest_spelling_of_a_taint_effect" {
  command = plan

  variables {
    taints = {
      dedicated = {
        key    = "workload"
        effect = "NoSchedule"
      }
    }
  }

  expect_failures = [var.taints]
}

# ── Prefix delegation depends on Nitro ───────────────────────────────────────

run "reject_t2_because_it_is_not_nitro" {
  command = plan

  variables {
    # Prefix delegation is only supported on the Nitro system. On t2 it silently does
    # nothing, so the pod ceiling stays at the secondary-IP limit with no error.
    instance_types = ["t2.medium"]
  }

  expect_failures = [var.instance_types]
}

# ── Architecture mismatches ──────────────────────────────────────────────────

run "reject_arm_ami_with_x86_instances" {
  command = plan

  variables {
    ami_type       = "AL2023_ARM_64_STANDARD"
    instance_types = ["m6i.large"]
  }

  # Fails at launch with a message about the image rather than the mismatch, and the
  # node group waits on instances that will never register before timing out.
  expect_failures = [aws_eks_node_group.this]
}

run "reject_graviton_instances_with_x86_ami" {
  command = plan

  variables {
    ami_type       = "AL2023_x86_64_STANDARD"
    instance_types = ["m7g.large"]
  }

  expect_failures = [aws_eks_node_group.this]
}

run "accept_matching_arm_pair" {
  command = plan

  variables {
    ami_type       = "AL2023_ARM_64_STANDARD"
    instance_types = ["m7g.large", "m6g.large"]
  }

  assert {
    condition     = aws_eks_node_group.this.ami_type == "AL2023_ARM_64_STANDARD"
    error_message = "a matching ARM AMI and Graviton instance pair should be accepted."
  }
}

# ── Sizing ───────────────────────────────────────────────────────────────────

run "reject_desired_size_above_max" {
  command = plan

  variables {
    desired_size = 5
    min_size     = 1
    max_size     = 4
  }

  expect_failures = [aws_eks_node_group.this]
}

run "reject_desired_size_below_min" {
  command = plan

  variables {
    desired_size = 1
    min_size     = 2
    max_size     = 4
  }

  expect_failures = [aws_eks_node_group.this]
}

run "reject_end_of_life_amazon_linux_2" {
  command = plan

  variables {
    ami_type = "AL2_x86_64"
  }

  expect_failures = [var.ami_type]
}

# ── Inventory ────────────────────────────────────────────────────────────────

run "inventory_flags_an_interruptible_pool" {
  command = plan

  variables {
    capacity_type = "SPOT"
  }

  # A SPOT pool holding anything with a PVC is a recurring mistake: the node is
  # reclaimed with two minutes' notice and the volume is stranded in one zone.
  assert {
    condition     = output.inventory.interruptible == true
    error_message = "a SPOT pool must be reported as interruptible."
  }
}

run "inventory_reports_the_pool_shape" {
  command = plan

  assert {
    condition = (
      output.inventory.desired_size == 2 &&
      output.inventory.max_size == 4 &&
      one(output.inventory.instance_types) == "m6i.large" &&
      output.inventory.interruptible == false
    )
    error_message = "inventory should record the pool's capacity shape."
  }
}
