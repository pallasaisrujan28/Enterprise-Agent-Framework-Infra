# S3 bucket for agent workspace files.
#
# Each user's files live under workspaces/{user_id}/{session_id}/.
# The IAM policy on the agent role is scoped to workspaces/* but per-user
# isolation is enforced by the application layer (the agent only ever writes
# to its own user prefix).
#
# S3 Vectors for semantic search (RAG documents) is a separate namespace —
# created via the AgentCore/Bedrock APIs, not Terraform, since it's managed
# as a service endpoint.

resource "aws_s3_bucket" "workspaces" {
  bucket        = "eaf-dev-agent-workspaces-${var.account_id}"
  force_destroy = true # dev only — easy cleanup

  tags = {
    ManagedBy   = "terraform"
    Environment = "dev"
    Purpose     = "agent-workspace-files"
  }
}

resource "aws_s3_bucket_versioning" "workspaces" {
  bucket = aws_s3_bucket.workspaces.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "workspaces" {
  bucket = aws_s3_bucket.workspaces.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "workspaces" {
  bucket = aws_s3_bucket.workspaces.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: auto-expire session files after 30 days in dev.
resource "aws_s3_bucket_lifecycle_configuration" "workspaces" {
  bucket = aws_s3_bucket.workspaces.id

  rule {
    id     = "expire-session-files"
    status = "Enabled"

    filter {
      prefix = "workspaces/"
    }

    expiration {
      days = 30
    }
  }
}
