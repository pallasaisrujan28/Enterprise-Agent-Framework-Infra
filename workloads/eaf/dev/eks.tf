# EKS cluster for EAF agent workloads.
#
# Dev sizing: single-AZ node group, t3.medium, min=1 max=3.
# IRSA (IAM Roles for Service Accounts) is enabled — this is how the agent
# pod gets Bedrock and AgentCore credentials without storing any secrets.

# ── IAM: cluster role ──────────────────────────────────────────────────────────

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { ManagedBy = "terraform" }
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── IAM: node group role ───────────────────────────────────────────────────────

resource "aws_iam_role" "nodes" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { ManagedBy = "terraform" }
}

resource "aws_iam_role_policy_attachment" "nodes_worker" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "nodes_cni" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "nodes_ecr" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ── Security groups ────────────────────────────────────────────────────────────

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS cluster control plane security group"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = { Name = "${var.cluster_name}-cluster-sg", ManagedBy = "terraform" }
}

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "EKS worker nodes security group"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
    description = "Allow intra-node communication"
  }

  ingress {
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster.id]
    description     = "Allow control plane to reach nodes"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = { Name = "${var.cluster_name}-nodes-sg", ManagedBy = "terraform" }
}

# ── EKS cluster ────────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true # set to false once kubectl access is via VPN/bastion
  }

  # Enable IRSA — required for agent pods to assume IAM roles.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = { ManagedBy = "terraform", Environment = "dev" }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
  ]
}

# OIDC provider — enables IRSA.
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = { ManagedBy = "terraform" }
}

# ── EKS managed node group ─────────────────────────────────────────────────────

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }

  labels = { Environment = "dev", ManagedBy = "terraform" }

  tags = { ManagedBy = "terraform" }

  depends_on = [
    aws_iam_role_policy_attachment.nodes_worker,
    aws_iam_role_policy_attachment.nodes_cni,
    aws_iam_role_policy_attachment.nodes_ecr,
  ]
}

# ── Core EKS add-ons ───────────────────────────────────────────────────────────

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.default]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
}

# EBS CSI driver — required for dynamic EBS volume provisioning in EKS 1.23+.
# The controller pods use IRSA (service account annotation) to get EC2 permissions.
# Without the IRSA role, the controller crashes: "no EC2 IMDS role found".

data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
  tags               = { ManagedBy = "terraform" }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.default, aws_iam_role_policy_attachment.ebs_csi]
}

import {
  to = aws_eks_addon.ebs_csi_driver
  id = "eaf-dev:aws-ebs-csi-driver"
}

# Default StorageClass — marks gp2 as the cluster default so PVCs with no
# storageClassName are satisfied automatically by EBS gp2 volumes.
resource "kubernetes_storage_class" "gp2_default" {
  metadata {
    name = "gp2"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type = "gp2"
  }

  depends_on = [aws_eks_addon.ebs_csi_driver]
}

# ── Langfuse node group ────────────────────────────────────────────────────────
# ClickHouse needs more memory than our default t3.medium nodes (2 vCPU, 4 GB).
# A dedicated t3.large node group (2 vCPU, 8 GB) keeps Langfuse isolated from
# agent workloads and prevents ClickHouse from evicting agent pods.

resource "aws_eks_node_group" "langfuse" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "langfuse"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = ["t3.large"]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  # Taint: only pods that tolerate this run on Langfuse nodes.
  # Prevents agent pods from being scheduled here.
  taint {
    key    = "dedicated"
    value  = "langfuse"
    effect = "NO_SCHEDULE"
  }

  labels = { dedicated = "langfuse", ManagedBy = "terraform" }

  tags = { ManagedBy = "terraform" }

  depends_on = [
    aws_iam_role_policy_attachment.nodes_worker,
    aws_iam_role_policy_attachment.nodes_cni,
    aws_iam_role_policy_attachment.nodes_ecr,
  ]
}

# ── EKS access entry for OrganizationAccountAccessRole ────────────────────────
# The Helm provider (used by Langfuse Terraform resources) runs `aws eks get-token`
# as OrganizationAccountAccessRole. This access entry grants it cluster admin
# so the Helm provider can create Kubernetes resources.

resource "aws_eks_access_entry" "org_role" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:role/OrganizationAccountAccessRole"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "org_role_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:role/OrganizationAccountAccessRole"
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.org_role]
}

# EKS access entry for the new workload deployer role.
# Allows Helm provider to authenticate to EKS when deploying via this role.
resource "aws_eks_access_entry" "workload_deployer" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.workload_deployer.arn
  type          = "STANDARD"
  depends_on    = [aws_iam_role.workload_deployer]
}

resource "aws_eks_access_policy_association" "workload_deployer_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.workload_deployer.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.workload_deployer]
}

import {
  to = aws_eks_access_entry.org_role
  id = "eaf-dev:arn:aws:iam::718438899462:role/OrganizationAccountAccessRole"
}

# ── Operator access — SSO admin role ─────────────────────────────────────────
# Grants kubectl cluster-admin to the ops role (SSO administrator).
# Having IAM AdministratorAccess alone is not enough to use kubectl — EKS
# requires an explicit access entry. Without this, operators can manage the
# cluster infrastructure via AWS API but cannot run kubectl commands.

resource "aws_eks_access_entry" "ops" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.ops_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "ops_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.ops_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.ops]
}
