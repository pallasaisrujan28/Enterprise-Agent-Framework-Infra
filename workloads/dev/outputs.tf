output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority" {
  description = "Base64-encoded certificate authority data."
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "agent_role_arn" {
  description = "IAM role ARN for the agent pod (IRSA). Set as AWS_ROLE_ARN in the Kubernetes ServiceAccount annotation."
  value       = aws_iam_role.agent.arn
}

output "db_endpoint" {
  description = "Aurora writer endpoint for LangGraph PostgresSaver."
  value       = aws_rds_cluster.aurora.endpoint
}

output "db_credentials_secret_arn" {
  description = "Secrets Manager ARN for DB credentials. Mount in the agent pod or read at startup."
  value       = aws_secretsmanager_secret.db_password.arn
}

output "workspaces_bucket" {
  description = "S3 bucket for agent workspace files."
  value       = aws_s3_bucket.workspaces.id
}

output "primary_model_id" {
  description = "Bedrock model ID for primary reasoning."
  value       = var.bedrock_primary_model
}

output "fast_model_id" {
  description = "Bedrock model ID for fast/cheap operations."
  value       = var.bedrock_fast_model
}

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (for additional deployments)."
  value       = aws_subnet.private[*].id
}
