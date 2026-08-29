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

# Vulnerability scanning is handled in the agent deployment pipeline:
#   pip-audit  → scans Python packages before building the image (fast, early)
#   trivy      → scans the Docker image after build, before push to ECR
# Inspector is not used — pipeline scanning catches issues earlier and is free.
# Add Inspector if compliance requires ongoing rescan of deployed images.

# ── Tool images ────────────────────────────────────────────────────────────────
#
# The build-tool-images workflow builds security-patched versions of every
# open-source tool image and pushes them here. EKS pods pull from these
# repos — never directly from DockerHub or GHCR.
#
# Repos mirror the matrix in .github/workflows/build-tool-images.yml.

locals {
  tool_images = ["tools/searxng", "tools/firecrawl", "tools/firecrawl-playwright"]
}

resource "aws_ecr_repository" "tools" {
  for_each = toset(local.tool_images)

  name                 = each.key
  image_tag_mutability = "MUTABLE" # tool images use :latest tag

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }

  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
    Purpose     = "tool-container-images"
  }
}

resource "aws_ecr_lifecycle_policy" "tools" {
  for_each   = aws_ecr_repository.tools
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
