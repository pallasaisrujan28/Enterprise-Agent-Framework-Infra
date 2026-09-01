data "aws_caller_identity" "current" {}

locals {
  # The identity EKS actually sees.
  #
  # The provider assumes OrganizationAccountAccessRole, so every API call this layer
  # makes — including cluster creation — comes from that role inside EAF-DEV. It is
  # therefore the principal that needs the cluster-admin access entry.
  #
  # NOT eaf-baseline-dev-role: that lives in the management account, and an access
  # entry principal must be an IAM role in the cluster's own account. Naming the
  # wrong one produces a cluster the pipeline cannot administer, discovered at the
  # first kubectl call rather than at apply.
  deployer_role_arn = "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole"

  eks_cluster_admin_policy = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  # Boundary exemption, applied to all four roles below.
  #
  # eaf-workload-boundary exists to cap roles that CI creates for workloads, and it
  # denies ec2:* and eks:*. Attaching it to a cluster or node role would deny exactly
  # what those roles exist to do.
  #
  # These four are not the class of role a boundary protects against. Each is assumed
  # only by an AWS service principal — eks.amazonaws.com, ec2.amazonaws.com, or
  # pods.eks.amazonaws.com for a single named service account — and each carries only
  # AWS-managed policies. There is no path for a human or a pipeline to assume them,
  # and no inline policy to widen.
  service_role_boundary_exemption = join(" ", [
    "Assumed only by an AWS service principal and carrying only AWS-managed policies.",
    "eaf-workload-boundary denies ec2:* and eks:*, which is precisely what these roles",
    "exist to do, so attaching it would break the cluster rather than cap it. The cap",
    "here is the trust policy and the managed policy, both of which are narrow."
  ])
}

# ── Network ───────────────────────────────────────────────────────────────────

module "network" {
  source = "../../../modules/network"

  org_prefix  = var.org_prefix
  environment = var.environment
  owner       = var.owner

  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway

  # subnet_newbits defaults to 4, giving /20s. Not /24s: prefix delegation hands each
  # node a /28 at a time, and a /24 leaves 251 usable addresses — about two nodes at
  # the 110-pod ceiling. A /20 gives 4091, about 36 nodes.
}

# ── IAM roles ─────────────────────────────────────────────────────────────────
#
# All four go through modules/iam-role. No root module writes aws_iam_role directly,
# so the naming, tagging and boundary rules apply here too.

module "eks_cluster_role" {
  source = "../../../modules/iam-role"

  org_prefix  = var.org_prefix
  environment = var.environment
  layer       = "platform"
  purpose     = "eks-cluster"
  description = "Assumed by the EKS control plane to manage load balancers, network interfaces and security groups on the cluster's behalf."
  owner       = var.owner

  boundary_exemption_reason = local.service_role_boundary_exemption

  trust = {
    type        = "aws_service"
    aws_service = { service_principals = ["eks.amazonaws.com"] }
  }

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
  ]
}

module "eks_node_role" {
  source = "../../../modules/iam-role"

  org_prefix  = var.org_prefix
  environment = var.environment
  layer       = "platform"
  purpose     = "eks-node"
  description = "Instance profile role for managed node group instances. Registers the node with the cluster and pulls images from ECR."
  owner       = var.owner

  boundary_exemption_reason = local.service_role_boundary_exemption

  trust = {
    type        = "aws_service"
    aws_service = { service_principals = ["ec2.amazonaws.com"] }
  }

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",

    # PullOnly, not ReadOnly. Nodes need to pull images, not to enumerate
    # repositories or read image metadata across the registry.
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",

    # DELIBERATELY ABSENT: AmazonEKS_CNI_Policy.
    #
    # It permits attaching and detaching network interfaces and assigning IP
    # addresses. On the node role, EVERY pod on the node inherits it through the
    # instance metadata service — so any compromised container can rewrite the node's
    # networking. It belongs on the vpc-cni add-on's own Pod Identity role, below.
  ]
}

# vpc-cni and the EBS CSI driver are the only two core add-ons that need AWS
# permissions. Verified rather than assumed:
#
#   aws eks describe-addon-configuration --addon-name NAME --addon-version V
#
# coredns and kube-proxy return no Pod Identity configuration at all, so they get no
# role. Two fewer roles than the original design assumed.

module "vpc_cni_role" {
  source = "../../../modules/iam-role"

  org_prefix  = var.org_prefix
  environment = var.environment
  layer       = "platform"
  purpose     = "vpc-cni"
  description = "Used by the aws-node DaemonSet to attach network interfaces and assign pod IP addresses. Holds the CNI policy so the node role does not."
  owner       = var.owner

  boundary_exemption_reason = local.service_role_boundary_exemption

  trust = {
    type = "eks_pod_identity"
    eks_pod_identity = {
      namespace       = "kube-system"
      service_account = "aws-node"

      # cluster_names deliberately omitted. Reuse across clusters is one of Pod
      # Identity's real advantages, and pinning it here would forfeit that for no
      # gain: the namespace and service-account conditions already mean only the CNI
      # can use this role.
    }
  }

  managed_policy_arns = [
    # No service-role/ path on this one, unlike AmazonEBSCSIDriverPolicy below. The
    # paths are inconsistent and a wrong one fails at apply with policy-not-found.
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
  ]
}

module "ebs_csi_role" {
  source = "../../../modules/iam-role"

  org_prefix  = var.org_prefix
  environment = var.environment
  layer       = "platform"
  purpose     = "ebs-csi"
  description = "Used by the EBS CSI controller to create, attach and delete EBS volumes for PersistentVolumeClaims."
  owner       = var.owner

  boundary_exemption_reason = local.service_role_boundary_exemption

  trust = {
    type = "eks_pod_identity"
    eks_pod_identity = {
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
    }
  }

  managed_policy_arns = [
    # V2, which is what describe-addon-configuration recommends. Note it has NO
    # service-role/ path, while the original AmazonEBSCSIDriverPolicy does.
    "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2",
  ]
}

# ── Cluster ───────────────────────────────────────────────────────────────────

module "eks_cluster" {
  source = "../../../modules/eks-cluster"

  org_prefix  = var.org_prefix
  environment = var.environment
  owner       = var.owner

  kubernetes_version = var.kubernetes_version
  cluster_role_arn   = module.eks_cluster_role.arn

  # Private subnets for the control plane's cross-account network interfaces. The set
  # of availability zones is durable: AWS requires any subnet added later to be in the
  # same zones.
  subnet_ids = module.network.private_subnet_ids

  endpoint_public_access  = true
  endpoint_private_access = true
  public_access_cidrs     = var.public_access_cidrs

  # bootstrap_cluster_creator_admin_permissions stays false, the module default, so
  # every administrator is an explicit resource. The entry below is what makes the
  # cluster reachable at all.
  access_entries = merge(
    {
      deployer = {
        principal_arn = local.deployer_role_arn
        policies      = [{ policy_arn = local.eks_cluster_admin_policy, scope_type = "cluster" }]
      }
    },
    {
      for arn in var.additional_cluster_admin_role_arns :
      "admin-${reverse(split("/", arn))[0]}" => {
        principal_arn = arn
        policies      = [{ policy_arn = local.eks_cluster_admin_policy, scope_type = "cluster" }]
      }
    },
  )
}

# ── Add-ons, part 1: before the node group ────────────────────────────────────
#
# These three must be ACTIVE before any node joins. A node that registers with no CNI
# fails its health check with `NodeCreationFailure: NetworkPluginNotReady` and stays
# NotReady — and the node group does not fail fast, it waits then times out.

module "addon_vpc_cni" {
  source = "../../../modules/eks-addon"

  org_prefix   = var.org_prefix
  environment  = var.environment
  owner        = var.owner
  cluster_name = module.eks_cluster.name

  addon_name    = "vpc-cni"
  addon_version = var.addon_versions.vpc_cni

  # PREFIX DELEGATION, ON FROM THE FIRST APPLY.
  #
  # This cannot be retrofitted. It changes how the CNI allocates addresses to an
  # instance AT LAUNCH, so turning it on later leaves existing nodes untouched and
  # requires replacing them.
  #
  # Without it an m6i.large tops out at 29 pods while barely touching 8 GiB of memory
  # — measured, not estimated. With it the ceiling is the Kubernetes-recommended 110.
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"

      # WARM_PREFIX_TARGET is deliberately NOT set. It allocates a whole spare /28
      # once a single address from the current prefix is used, which consumes subnet
      # space for no benefit at this size. AWS advises using it only after
      # considering the cost.
    }
  })

  pod_identity = {
    role_arn        = module.vpc_cni_role.arn
    service_account = "aws-node"
  }
}

module "addon_kube_proxy" {
  source = "../../../modules/eks-addon"

  org_prefix   = var.org_prefix
  environment  = var.environment
  owner        = var.owner
  cluster_name = module.eks_cluster.name

  addon_name    = "kube-proxy"
  addon_version = var.addon_versions.kube_proxy

  # No pod_identity: kube-proxy needs no AWS permissions.
}

module "addon_pod_identity_agent" {
  source = "../../../modules/eks-addon"

  org_prefix   = var.org_prefix
  environment  = var.environment
  owner        = var.owner
  cluster_name = module.eks_cluster.name

  addon_name    = "eks-pod-identity-agent"
  addon_version = var.addon_versions.pod_identity_agent

  # Before the node group, and not only for tidiness: this agent is what vends
  # credentials to aws-node, so without it on the node the CNI cannot assume its role.
  # It runs with hostNetwork, so it does not itself need the CNI.
}

# ── Node group ────────────────────────────────────────────────────────────────

module "node_group_default" {
  source = "../../../modules/eks-node-group"

  org_prefix  = var.org_prefix
  environment = var.environment
  owner       = var.owner
  pool        = "default"

  cluster_name  = module.eks_cluster.name
  node_role_arn = module.eks_node_role.arn
  subnet_ids    = module.network.private_subnet_ids

  instance_types = var.node_instance_types
  desired_size   = var.node_desired_size
  min_size       = var.node_min_size
  max_size       = var.node_max_size
  disk_size      = var.node_disk_size

  # NO TAINTS. The design's earlier `langfuse` pool and its taint are gone: with one
  # pool tainted, untainted capacity was a single t3.medium at 17 pod slots, which
  # caused the starvation the taint was meant to prevent. A dedicated pool earns its
  # complexity when there is contention to manage.
  labels = {
    "eaf.io/pool" = "default"
  }

  # The ordering the modules cannot enforce. Terraform infers the cluster dependency
  # from module.eks_cluster.name, but nothing in the arguments says these add-ons must
  # come first.
  depends_on = [
    module.addon_vpc_cni,
    module.addon_kube_proxy,
    module.addon_pod_identity_agent,
  ]
}

# ── Add-ons, part 2: after the node group ─────────────────────────────────────
#
# These two need somewhere to schedule. On an empty cluster their pods stay Pending,
# the add-on reports DEGRADED, and Terraform waits until the timeout.

module "addon_coredns" {
  source = "../../../modules/eks-addon"

  org_prefix   = var.org_prefix
  environment  = var.environment
  owner        = var.owner
  cluster_name = module.eks_cluster.name

  addon_name    = "coredns"
  addon_version = var.addon_versions.coredns

  # No pod_identity: coredns needs no AWS permissions.

  depends_on = [module.node_group_default]
}

module "addon_ebs_csi" {
  source = "../../../modules/eks-addon"

  org_prefix   = var.org_prefix
  environment  = var.environment
  owner        = var.owner
  cluster_name = module.eks_cluster.name

  addon_name    = "aws-ebs-csi-driver"
  addon_version = var.addon_versions.ebs_csi_driver

  pod_identity = {
    role_arn        = module.ebs_csi_role.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [module.node_group_default]
}
