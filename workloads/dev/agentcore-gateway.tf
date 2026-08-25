# AGENTCORE GATEWAY — managed MCP server for EAF tool routing.
#
# Architecture:
#
#   Agent pod (IRSA)
#     → reads Secrets Manager: { client_id, client_secret, token_endpoint }
#     → POST Cognito token endpoint → access_token (JWT, 1h TTL)
#     → MCP ListTools call to Gateway with Bearer token
#       → Gateway validates JWT against Cognito User Pool
#       → Gateway routes tool call to registered target
#
# Components in this file:
#   1. Cognito User Pool         — issues OAuth 2.0 JWTs for M2M auth
#   2. Cognito Resource Server   — defines the tools/* scope namespace
#   3. Cognito App Client        — agent's M2M credentials (client_credentials)
#   4. Secrets Manager           — stores client_id + secret for the agent pod
#   5. IAM execution role        — what the Gateway runs as (calls targets)
#   6. Inline policy on agent    — Secrets Manager read for the creds secret
#   7. AgentCore Gateway         — the managed MCP server resource
#   8. SSM parameters            — wires Gateway config to K8s deployment env vars

# ── Cognito User Pool ──────────────────────────────────────────────────────────

resource "aws_cognito_user_pool" "gateway" {
  name = "eaf-dev-gateway"

  # Machine-to-machine only — no human sign-up, no self-service.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # Required even for M2M-only pools.
  password_policy {
    minimum_length                   = 16
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 1
  }

  # No MFA for machine clients — auth is client_credentials (secret-based).
  mfa_configuration = "OFF"

  tags = {
    ManagedBy   = "terraform"
    Environment = "dev"
  }
}

# ── Cognito User Pool Domain ───────────────────────────────────────────────────
# Provides the OAuth 2.0 token endpoint that the agent calls to get a JWT:
#   https://eaf-dev-gateway-<account_id>.auth.eu-west-2.amazoncognito.com/oauth2/token

resource "aws_cognito_user_pool_domain" "gateway" {
  domain       = "eaf-dev-gateway-${var.account_id}"
  user_pool_id = aws_cognito_user_pool.gateway.id
}

# ── Cognito Resource Server ────────────────────────────────────────────────────
# Defines the audience URI and OAuth scopes for the Gateway.
# The identifier becomes the `aud` claim in the JWT.

resource "aws_cognito_resource_server" "gateway_tools" {
  name         = "EAF Tools Gateway"
  identifier   = "https://tools.eaf.dev"
  user_pool_id = aws_cognito_user_pool.gateway.id

  # Coarse-grained: one scope that grants access to all tools.
  # Fine-grained per-tool scopes can be added here when needed.
  scope {
    scope_name        = "invoke"
    scope_description = "Invoke any registered tool via the MCP Gateway"
  }

  scope {
    scope_name        = "web_search"
    scope_description = "Invoke the web_search tool only"
  }

  scope {
    scope_name        = "fetch"
    scope_description = "Invoke the fetch_and_store tool only"
  }

  scope {
    scope_name        = "memory"
    scope_description = "Invoke the search_memory tool only"
  }
}

# ── Cognito App Client (machine-to-machine) ────────────────────────────────────
# One client per agent identity. Currently one agent; add more clients for
# additional agents or external consumers without touching IAM.

resource "aws_cognito_user_pool_client" "eaf_agent" {
  name         = "eaf-agent"
  user_pool_id = aws_cognito_user_pool.gateway.id

  generate_secret = true # required for client_credentials flow

  # client_credentials is the M2M grant type — no user involved.
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]

  # The agent gets the coarse invoke scope.
  # Scope down to per-tool scopes if multi-tenant isolation is required.
  allowed_oauth_scopes = [
    "${aws_cognito_resource_server.gateway_tools.identifier}/invoke",
  ]

  supported_identity_providers = ["COGNITO"]

  access_token_validity  = 1   # hour — short-lived, refreshed by token manager
  refresh_token_validity = 30  # days (not used in M2M, but Cognito requires it)
  token_validity_units {
    access_token  = "hours"
    refresh_token = "days"
  }

  # Prevent public flows — only the confidential client flow is allowed.
  explicit_auth_flows = []
}

# ── Secrets Manager — client credentials ──────────────────────────────────────
# The agent pod reads this at startup to obtain Cognito tokens.
# Secret is JSON: { client_id, client_secret, token_endpoint, scope }
# The agent's IRSA role is granted GetSecretValue on this ARN only.

resource "aws_secretsmanager_secret" "gateway_client_creds" {
  name                    = "eaf-dev/gateway/agent-client-creds"
  description             = "OAuth 2.0 client credentials for the EAF agent to authenticate with AgentCore Gateway"
  recovery_window_in_days = 7

  tags = {
    ManagedBy   = "terraform"
    Environment = "dev"
  }
}

resource "aws_secretsmanager_secret_version" "gateway_client_creds" {
  secret_id = aws_secretsmanager_secret.gateway_client_creds.id

  secret_string = jsonencode({
    client_id      = aws_cognito_user_pool_client.eaf_agent.id
    client_secret  = aws_cognito_user_pool_client.eaf_agent.client_secret
    token_endpoint = "https://${aws_cognito_user_pool_domain.gateway.domain}.auth.${var.region}.amazoncognito.com/oauth2/token"
    scope          = "${aws_cognito_resource_server.gateway_tools.identifier}/invoke"
  })
}

# ── IAM: Secrets Manager permission on agent IRSA role ────────────────────────
# Scoped to this one secret only — no broad Secrets Manager access.

data "aws_iam_policy_document" "agent_gateway_secrets" {
  statement {
    sid    = "ReadGatewayClientCreds"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.gateway_client_creds.arn]
  }
}

resource "aws_iam_role_policy" "agent_gateway_secrets" {
  name   = "gateway-client-creds"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent_gateway_secrets.json
}

# ── IAM: AgentCore Gateway execution role ─────────────────────────────────────
# This is the role the Gateway ITSELF assumes when routing tool calls to targets.
# Not the agent's role — the Gateway's service role.

data "aws_iam_policy_document" "gateway_execution_trust" {
  statement {
    sid    = "AgentCoreServiceTrust"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    # Source account condition prevents confused deputy attacks.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "gateway_execution" {
  name               = "eaf-dev-gateway-execution-role"
  description        = "Role assumed by AgentCore Gateway when invoking tool targets."
  assume_role_policy = data.aws_iam_policy_document.gateway_execution_trust.json

  permissions_boundary = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:policy/eaf-workload-boundary"

  tags = {
    ManagedBy   = "terraform"
    Environment = "dev"
  }
}

data "aws_iam_policy_document" "gateway_execution" {
  # Future Lambda targets: Gateway invokes Lambda functions named eaf-dev-tool-*
  statement {
    sid    = "InvokeLambdaTargets"
    effect = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [
      "arn:${data.aws_partition.current.partition}:lambda:${var.region}:${var.account_id}:function:eaf-dev-tool-*",
    ]
  }

  # CloudWatch Logs: Gateway emits invocation logs.
  statement {
    sid    = "GatewayLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${var.region}:${var.account_id}:log-group:/aws/bedrock-agentcore/gateway/*",
    ]
  }

  # Bedrock invoke: Gateway may call models when doing schema validation.
  statement {
    sid    = "BedrockInvokeForValidation"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gateway_execution" {
  name   = "eaf-dev-gateway-execution"
  role   = aws_iam_role.gateway_execution.id
  policy = data.aws_iam_policy_document.gateway_execution.json
}

# ── AgentCore Gateway ──────────────────────────────────────────────────────────
# The managed MCP server resource.
#
# Provider status note:
#   The hashicorp/aws provider is adding AgentCore resources in v5.x.
#   If `terraform plan` fails with "unsupported argument" or "resource type not
#   supported", check the provider changelog for the exact resource name and
#   update accordingly. The awscc provider (AWS Cloud Control API) may have it
#   sooner under awscc_bedrock_agentcore_gateway.
#
# The resource is written here with the most current documented API shape.
# Once verified against the provider, remove the lifecycle ignore_changes guard.

resource "aws_bedrockagentcore_gateway" "eaf" {
  name        = "eaf-dev-tools-gateway"
  description = "MCP tool gateway for EAF agent. All tool calls route through here — access control via Cognito JWT scopes."

  role_arn = aws_iam_role.gateway_execution.arn

  # Cognito JWT authorizer: validates tokens issued by our User Pool.
  authorizer_configuration {
    type = "COGNITO_USER_POOL"

    cognito_user_pool_configuration {
      user_pool_arn    = aws_cognito_user_pool.gateway.arn
      app_client_id    = aws_cognito_user_pool_client.eaf_agent.id
      discovery_url    = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.gateway.id}/.well-known/openid-configuration"
    }
  }

  # Data residency: all routing in eu-west-2.
  # VPC config lets the Gateway reach internal K8s tool services.
  vpc_configuration {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.gateway_egress.id]
  }

  tags = {
    ManagedBy   = "terraform"
    Environment = "dev"
  }

  # Once created, the endpoint URL is used by the agent. Ignore auth changes
  # after initial creation — rotate via Cognito, not Terraform.
  lifecycle {
    ignore_changes = [authorizer_configuration]
  }
}

# Security group: Gateway → K8s tool services (outbound only, no inbound).
resource "aws_security_group" "gateway_egress" {
  name        = "eaf-dev-gateway-egress"
  description = "AgentCore Gateway outbound to K8s tool services"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "HTTPS to tool backends in cluster"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  egress {
    description = "HTTP to tool backends in cluster (SearXNG:8080, Crawl4AI:11235, Qdrant:6333)"
    from_port   = 6333
    to_port     = 11235
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  tags = { ManagedBy = "terraform", Name = "eaf-dev-gateway-egress" }
}

# ── SSM parameters — consumed by K8s deployment as env vars ──────────────────
# These let the EKS deployment pick up the Gateway config without hard-coding
# ARNs or URLs in Kubernetes manifests.

resource "aws_ssm_parameter" "gateway_endpoint" {
  name        = "/eaf/dev/gateway/endpoint"
  type        = "String"
  description = "AgentCore Gateway MCP endpoint URL"
  value       = aws_bedrockagentcore_gateway.eaf.endpoint_url
}

resource "aws_ssm_parameter" "gateway_creds_secret_arn" {
  name        = "/eaf/dev/gateway/client-creds-secret-arn"
  type        = "String"
  description = "ARN of the Secrets Manager secret containing Cognito client credentials"
  value       = aws_secretsmanager_secret.gateway_client_creds.arn
}

resource "aws_ssm_parameter" "cognito_user_pool_id" {
  name        = "/eaf/dev/gateway/cognito-user-pool-id"
  type        = "String"
  description = "Cognito User Pool ID backing the AgentCore Gateway authorizer"
  value       = aws_cognito_user_pool.gateway.id
}
