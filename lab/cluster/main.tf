# lab/cluster — VPC, EKS and nodes, applied from a terminal.
#
# LOCAL STATE, and that is the whole point of this directory. `workloads/` keeps state in the
# management account, which these SSO credentials get a 403 on, so every change there needs a
# dispatched workflow. Here `terraform apply` just works.
#
# Reuses the same verified modules as `workloads/dev/platform` — network, eks-cluster,
# eks-addon, eks-node-group. What differs is the composition around them: no cross-account
# assume_role, no permissions boundary, and the operator's own SSO role as cluster admin.

terraform {
  required_version = "~> 1.13"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # NO BACKEND BLOCK. State is a file in this directory.
  #
  # The trade is real and worth knowing: delete terraform.tfstate and Terraform forgets a
  # running cluster while AWS keeps charging for it. `make teardown-check` is the recovery
  # path — it reads AWS rather than state, so it can still tell you what exists.
}

# No assume_role. These credentials are already administrator in the target account, and the
# hop `workloads/` makes into OrganizationAccountAccessRole exists only because its pipeline
# authenticates from the management account.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Layer     = "lab/cluster"
      Purpose   = "experimentation"
    }
  }
}

data "aws_caller_identity" "current" {}

# ── The operator's SSO role, discovered rather than hardcoded ──────────────────
#
# The suffix on an SSO role name is a permission-set id that changes if the set is recreated,
# so hardcoding it produces a cluster nobody can reach after an unrelated SSO change.
#
# THE ANCHORS ARE LOAD-BEARING. This account has BOTH `AdministratorAccess` and
# `AWSAdministratorAccess` permission sets. An unanchored pattern matches both and hands
# cluster-admin to whichever the API happened to return first.
data "aws_iam_roles" "operator" {
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
  name_regex  = "^AWSReservedSSO_${var.operator_permission_set}_[0-9a-f]+$"
}

locals {
  # THE FULL ARN, INCLUDING THE SSO PATH. An earlier version of this file stripped the path,
  # on the belief that EKS rejects it. That belief was wrong and it was tested the expensive
  # way: EKS answered
  #
  #   InvalidParameterException: The specified principalArn is invalid: invalid principal
  #
  # because the flattened ARN names a role that does not exist. The role genuinely lives at
  # /aws-reserved/sso.amazonaws.com/<region>/, and that is the ARN to hand EKS. Verified by
  # creating the entry with the CLI both ways: flattened rejected, full path accepted, and
  # kubectl worked immediately afterwards.
  operator_role_arn = one(data.aws_iam_roles.operator.arns)
}

check "operator_role_was_found" {
  assert {
    condition = length(data.aws_iam_roles.operator.arns) == 1
    error_message = join(" ", [
      "Expected exactly one SSO role matching AWSReservedSSO_${var.operator_permission_set}_*,",
      "found ${length(data.aws_iam_roles.operator.arns)}.",
      "Without it the cluster is created with no administrator and kubectl cannot connect.",
      "Check the permission set name with:",
      "aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/",
    ])
  }
}

# ── Network ───────────────────────────────────────────────────────────────────

module "network" {
  source = "../../modules/network"

  org_prefix  = var.org_prefix
  environment = var.environment
  owner       = var.owner

  vpc_cidr = var.vpc_cidr
  az_count = 2

  # One NAT rather than one per AZ. Halves the hourly cost, and the failure it exposes — a
  # zone outage taking egress with it — does not matter for a lab.
  single_nat_gateway = true
}

# ── IAM ───────────────────────────────────────────────────────────────────────
#
# Inline, not `modules/iam-role`. That module requires a permissions boundary and generates
# names from a layer taxonomy, which is right for the reviewed path and friction here. Two
# roles with AWS-managed policies is the whole requirement.

data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.org_prefix}-${var.environment}-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  name               = "${var.org_prefix}-${var.environment}-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # The CNI policy on the NODE role, which works because aws-node runs with
    # hostNetwork: true — it IS the node, so it reaches instance metadata directly.
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# ── Pod Identity for the EBS CSI controller ───────────────────────────────────
#
# NOT OPTIONAL, AND I LEARNED THAT THE EXPENSIVE WAY. The first version of this file attached
# AmazonEBSCSIDriverPolicy to the node role and skipped Pod Identity "to save a moving part".
# The controller then sat in CrashLoopBackOff for twenty minutes, 1/6 containers ready, while
# the add-on hung in CREATING — the same shape as the 20-minute ebs-csi timeout that triggered
# this project's original teardown.
#
# The reason, from the controller's own logs:
#
#   Failed health check (verify network connection and IAM credentials): dry-run EC2 API call
#   failed: DescribeAvailabilityZones, get identity: get credentials: failed to refresh cached
#   credentials, no EC2 IMDS role found, ec2imds: GetMetadata, context deadline exceeded
#
# The controller is an ordinary pod, so instance metadata is one network hop away — and the
# managed node group sets HttpPutResponseHopLimit = 1, which blocks exactly that hop.
# Confirmed on the running instances rather than assumed. So there is no falling back to the
# node role: the credential chain has nowhere to go.
#
# aws-node gets away with it because it runs hostNetwork: true. That asymmetry is the whole
# explanation for why the CNI came up and the CSI driver did not.
data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.org_prefix}-${var.environment}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role = aws_iam_role.ebs_csi.name

  # V2, and the path matters. AmazonEBSCSIDriverPolicy lives under `service-role/`;
  # AmazonEBSCSIDriverPolicyV2 does not. Getting it wrong yields NoSuchEntity, which reads as
  # a typo in the policy name rather than a wrong path.
  policy_arn = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2"
}

# ── Cluster ───────────────────────────────────────────────────────────────────

module "eks_cluster" {
  source = "../../modules/eks-cluster"

  org_prefix  = var.org_prefix
  environment = var.environment
  owner       = var.owner

  kubernetes_version = var.kubernetes_version
  cluster_role_arn   = aws_iam_role.cluster.arn
  subnet_ids         = concat(module.network.private_subnet_ids, module.network.public_subnet_ids)

  # Public, from anywhere. Deliberate: this is how kubectl works from a laptop on a changing
  # IP without a bastion or a VPN. Authentication still gates access; the endpoint is open.
  endpoint_public_access  = true
  endpoint_private_access = true
  public_access_cidrs     = ["0.0.0.0/0"]

  # `api` only, never the deprecated aws-auth ConfigMap. Not configurable in the module
  # because the migration is one-way.
  #
  # THE OPERATOR'S OWN ROLE IS CLUSTER ADMIN. `workloads/` grants this to
  # OrganizationAccountAccessRole, which is why every kubectl call there needs
  # `--role-arn`. Granting it directly is the difference between kubectl working and a 401
  # that reads as a missing access entry.
  access_entries = {
    operator = {
      principal_arn = local.operator_role_arn
      policies = [{
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = {
          type = "cluster"
        }
      }]
    }
  }

  # `audit` left out. It is the highest-volume log type at roughly $0.60/GB ingested, and a
  # lab does not need a who-did-what trail. `api` alone is enough to debug a failing apply.
  enabled_cluster_log_types = ["api"]
  log_retention_days        = 7

  # Standard support, never extended. Extended is $0.50/hr ON TOP of the $0.10 per-cluster
  # charge — six times the price, and it is what made a 6-day-old cluster cost $85 in August.
  support_type = "STANDARD"

  deletion_protection = false
}

# ── Add-ons before the nodes ──────────────────────────────────────────────────
#
# ORDERING IS THE WHOLE REASON THESE ARE SEPARATE MODULE CALLS. A node joining a cluster with
# no CNI fails with NodeCreationFailure: NetworkPluginNotReady and stays NotReady. So the CNI,
# kube-proxy and the Pod Identity agent go in first.
#
# It cannot be expressed inside `modules/eks-cluster`: an add-on that needs the node group
# would make the module wait on it, and the node group waits on the cluster. A cycle.

module "addon_vpc_cni" {
  source = "../../modules/eks-addon"

  org_prefix    = var.org_prefix
  environment   = var.environment
  owner         = var.owner
  cluster_name  = module.eks_cluster.name
  addon_name    = "vpc-cni"
  addon_version = var.addon_versions.vpc_cni

  # PREFIX DELEGATION. Without it an m6i.xlarge caps at 58 pods; with it the ENI hands out
  # /28 prefixes instead of single addresses and the ceiling becomes the kubelet's 110.
  # The memory and RL stack is a lot of small pods, so this is the difference between it
  # fitting and pods sitting Pending on "Too many pods".
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })
}

module "addon_kube_proxy" {
  source = "../../modules/eks-addon"

  org_prefix    = var.org_prefix
  environment   = var.environment
  owner         = var.owner
  cluster_name  = module.eks_cluster.name
  addon_name    = "kube-proxy"
  addon_version = var.addon_versions.kube_proxy
}

module "addon_pod_identity" {
  source = "../../modules/eks-addon"

  org_prefix    = var.org_prefix
  environment   = var.environment
  owner         = var.owner
  cluster_name  = module.eks_cluster.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = var.addon_versions.pod_identity_agent
}

# ── Nodes ─────────────────────────────────────────────────────────────────────

module "nodes" {
  source = "../../modules/eks-node-group"

  org_prefix  = var.org_prefix
  environment = var.environment
  owner       = var.owner

  cluster_name  = module.eks_cluster.name
  node_role_arn = aws_iam_role.node.arn
  subnet_ids    = module.network.private_subnet_ids

  # One pool, named for what it is. The module is called once per pool by design, so a second
  # pool later — GPU nodes for RL training, say — is another module block rather than an edit.
  pool = "default"

  instance_types = var.instance_types
  desired_size   = var.node_count
  min_size       = 1
  max_size       = var.node_count + 2

  disk_size = var.node_disk_size

  # The CNI must be ACTIVE before a node tries to join. depends_on rather than a value
  # reference, because there is no attribute to consume — only an ordering requirement.
  depends_on = [
    module.addon_vpc_cni,
    module.addon_kube_proxy,
    module.addon_pod_identity,
  ]
}

# ── Add-ons that need somewhere to run ────────────────────────────────────────
#
# coredns and the EBS CSI driver schedule pods. On an empty cluster they sit DEGRADED until
# Terraform times out — which is the 20-minute ebs-csi failure that triggered the original
# teardown. They go after the node group.

module "addon_coredns" {
  source = "../../modules/eks-addon"

  org_prefix    = var.org_prefix
  environment   = var.environment
  owner         = var.owner
  cluster_name  = module.eks_cluster.name
  addon_name    = "coredns"
  addon_version = var.addon_versions.coredns

  depends_on = [module.nodes]
}

module "addon_ebs_csi" {
  source = "../../modules/eks-addon"

  org_prefix    = var.org_prefix
  environment   = var.environment
  owner         = var.owner
  cluster_name  = module.eks_cluster.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = var.addon_versions.ebs_csi

  # The service account name is not a guess — `aws eks describe-addon-configuration` reports
  # it, and the module's own documentation records the pairing:
  #   aws-ebs-csi-driver -> ebs-csi-controller-sa / AmazonEBSCSIDriverPolicyV2
  pod_identity = {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [module.nodes]
}
