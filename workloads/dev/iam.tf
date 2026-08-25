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
