# ECR repository for the agent Docker image.
#
# Every image pushed here is automatically scanned by Amazon Inspector.
# The agent's CI pipeline (in the agent code repo) pushes to this registry.
# The EKS node group IAM role has read access so pods can pull images.

resource "aws_ecr_repository" "agent" {
  name                 = "eaf/agent"
  image_tag_mutability = "IMMUTABLE" # same tag cannot be overwritten — forces versioned deploys

  image_scanning_configuration {
    scan_on_push = true # Amazon Inspector scans every image on push
  }

  encryption_configuration {
    encryption_type = "KMS" # encrypted at rest
  }

  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
    Purpose     = "agent-container-images"
  }
}

# Lifecycle policy: keep only the last 30 images.
# Prevents the registry filling up with old dev images.
resource "aws_ecr_lifecycle_policy" "agent" {
  repository = aws_ecr_repository.agent.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

# Enable Amazon Inspector v2 for this account.
# Scans ECR images for OS and language package vulnerabilities.
# Results appear in ECR console, Security Hub, and Inspector console.
resource "aws_inspector2_enabler" "this" {
  account_ids    = [var.account_id]
  resource_types = ["ECR", "EC2"]
}
