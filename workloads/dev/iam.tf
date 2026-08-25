# IAM role for the agent pod — IRSA (IAM Roles for Service Accounts).
#
# The agent pod assumes this role to call Bedrock, AgentCore services,
# S3 workspaces, and Secrets Manager. No credentials stored in the pod —
# the EKS OIDC provider handles the token exchange.

locals {
  oidc_provider = trimprefix(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://")
}

# ── Trust policy: EKS pod in the "eaf" namespace ──────────────────────────────

data "aws_iam_policy_document" "agent_trust" {
  statement {
    sid     = "EKSPodAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:eaf:eaf-agent"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent" {
  name               = "${var.cluster_name}-agent-role"
  description        = "Assumed by the EAF agent pod via IRSA. No credentials stored in the pod."
  assume_role_policy = data.aws_iam_policy_document.agent_trust.json

  # Permissions boundary from the account baseline — caps what this role can do
  # regardless of what policies are attached. Cannot be removed by this role.
  permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:policy/eaf-workload-boundary"

  tags = { ManagedBy = "terraform", Environment = "dev" }
}

# ── Bedrock: invoke approved models only ──────────────────────────────────────

data "aws_iam_policy_document" "agent_bedrock" {
  statement {
    sid    = "InvokeApprovedModels"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:bedrock:${var.region}::foundation-model/${var.bedrock_primary_model}",
      "arn:${data.aws_partition.current.partition}:bedrock:${var.region}::foundation-model/${var.bedrock_fast_model}",
    ]
  }
}

resource "aws_iam_role_policy" "agent_bedrock" {
  name   = "bedrock-invoke"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent_bedrock.json
}

# ── AgentCore: Memory and Gateway ─────────────────────────────────────────────

data "aws_iam_policy_document" "agent_agentcore" {
  statement {
    sid    = "AgentCoreMemory"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:CreateMemory",
      "bedrock-agentcore:GetMemory",
      "bedrock-agentcore:CreateMemoryRecord",
      "bedrock-agentcore:GetMemoryRecord",
      "bedrock-agentcore:RetrieveMemoryRecords",
      "bedrock-agentcore:DeleteMemoryRecord",
      "bedrock-agentcore:UpdateMemoryRecord",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AgentCoreGateway"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:InvokeAgentGateway",
      "bedrock-agentcore:InvokeAgentRuntime",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "agent_agentcore" {
  name   = "agentcore-access"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent_agentcore.json
}

# ── S3: workspace files (user-isolated prefix enforced by bucket policy) ───────

data "aws_iam_policy_document" "agent_s3" {
  statement {
    sid    = "WorkspaceAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.workspaces.arn,
      "${aws_s3_bucket.workspaces.arn}/workspaces/*",
    ]
  }
}

resource "aws_iam_role_policy" "agent_s3" {
  name   = "workspace-s3"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent_s3.json
}

# ── ECR: pull agent images ─────────────────────────────────────────────────────
# The node group role already has AmazonEC2ContainerRegistryReadOnly attached.
# The agent service account also gets explicit pull access for cross-account
# scenarios in the future.

data "aws_iam_policy_document" "agent_ecr" {
  statement {
    sid    = "PullAgentImage"
    effect = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "agent_ecr" {
  name   = "ecr-pull"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent_ecr.json
}

# --------------------------------------------------------------------------
# AGENT CI ROLE — assumed by Enterprise-Agent-Framework repo GitHub Actions
# --------------------------------------------------------------------------
#
# This role lets the agent code repo's CI pipeline:
#   1. Push Docker images to ECR in this account
#   2. Update the EKS deployment (rolling deploy via kubectl)
#
# Created here (in workloads/dev) because it is specific to this workload.
# It has nothing to do with the bootstrap/seed layer.
#
# The OIDC provider was created by the account baseline layer.
# Agent repo:  pallasaisrujan28/Enterprise-Agent-Framework  (id: 1317099884)
# Owner id:    194785418

locals {
  agent_repo_sub = "repo:pallasaisrujan28@194785418/Enterprise-Agent-Framework@1317099884:ref:refs/heads/*"
}

data "aws_iam_policy_document" "agent_ci_trust" {
  statement {
    sid     = "AgentRepoCIAccess"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${var.account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.agent_repo_sub]
    }
  }
}

resource "aws_iam_role" "agent_ci" {
  name        = "eaf-agent-ci-role"
  description = "Assumed by Enterprise-Agent-Framework CI to push images to ECR and deploy to EKS."

  assume_role_policy   = data.aws_iam_policy_document.agent_ci_trust.json
  max_session_duration = 3600

  permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:policy/eaf-workload-boundary"

  tags = { ManagedBy = "terraform", Environment = "dev" }
}

data "aws_iam_policy_document" "agent_ci_policy" {
  # ECR auth — needed to get a login token before docker push
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # ECR push — scoped to eaf/* repositories in this account only
  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ecr:${var.region}:${var.account_id}:repository/eaf/*",
    ]
  }

  # EKS describe cluster — needed to generate kubeconfig for kubectl
  statement {
    sid    = "EKSDescribe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
    ]
    resources = [aws_eks_cluster.this.arn]
  }
}

resource "aws_iam_role_policy" "agent_ci" {
  name   = "ecr-push-eks-deploy"
  role   = aws_iam_role.agent_ci.id
  policy = data.aws_iam_policy_document.agent_ci_policy.json
}

# --------------------------------------------------------------------------
# WORKLOAD DEPLOYER ROLE — direct OIDC to EAF-DEV (no management account hop)
# --------------------------------------------------------------------------
#
# WHY THIS EXISTS:
# The management account's OIDC should only handle org-level operations
# (seed, accounts). Workload deployments (EKS, VPC, ECR) belong in
# EAF-DEV directly — the management account should not be in the loop.
#
# This role trusts the GitHub OIDC provider INSIDE EAF-DEV (already created
# by the account baseline layer). The infra repo's deploy-eks-workload
# workflow will use this role on all deployments after it is first created.
#
# First deploy: still uses eaf-baseline-dev-role (bootstrap requirement)
# All future deploys: directly assume this role — no management account involved
#
# Infra repo: pallasaisrujan28/Enterprise-Agent-Framework-Infra (id: 1324052608)

locals {
  infra_repo_sub = "repo:pallasaisrujan28@194785418/Enterprise-Agent-Framework-Infra@1324052608:ref:refs/heads/*"
}

data "aws_iam_policy_document" "workload_deployer_trust" {
  statement {
    sid     = "InfraRepoDirect"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${var.account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.infra_repo_sub]
    }
  }
}

resource "aws_iam_role" "workload_deployer" {
  name        = "eaf-workload-dev-deployer-role"
  description = "Used by deploy-eks-workload to deploy infra directly to EAF-DEV. No management account hop."

  assume_role_policy   = data.aws_iam_policy_document.workload_deployer_trust.json
  max_session_duration = 7200

  # No permissions boundary — this role deploys infrastructure, not application code.
  # The SCP on the Workloads OU is the real ceiling.
  tags = { ManagedBy = "terraform", Environment = "dev" }
}

# AdministratorAccess within EAF-DEV.
# The SCP on the Workloads OU limits what this can actually do regardless:
# no long-lived credentials, no public S3, Bedrock locked to London.
resource "aws_iam_role_policy_attachment" "workload_deployer_admin" {
  role       = aws_iam_role.workload_deployer.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

# Cross-account S3: read/write the Terraform state for this workload layer.
# The state bucket lives in the management account (193027353132).
# The bucket policy (added in bootstrap/seed/main.tf) allows this role
# cross-account access to workloads/dev/* objects.
data "aws_iam_policy_document" "workload_deployer_state" {
  statement {
    sid    = "WorkloadDevStateCrossAccount"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::eaf-bootstrap-tfstate-193027353132",
      "arn:${data.aws_partition.current.partition}:s3:::eaf-bootstrap-tfstate-193027353132/workloads/dev/*",
    ]
  }
  statement {
    sid    = "WorkloadDevStateLock"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::eaf-bootstrap-tfstate-193027353132/workloads/dev/*.tflock"]
  }
}

resource "aws_iam_role_policy" "workload_deployer_state" {
  name   = "cross-account-state-access"
  role   = aws_iam_role.workload_deployer.id
  policy = data.aws_iam_policy_document.workload_deployer_state.json
}
