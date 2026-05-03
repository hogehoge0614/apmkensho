# ============================================================
# ECR Repositories - one per microservice
# ============================================================

resource "aws_ecr_repository" "services" {
  for_each = toset(var.services)

  name                 = "${var.cluster_name}/${each.value}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = {
    Name = "${var.cluster_name}/${each.value}"
  }
}

# ADOT Collector — mirrored image for Fargate (accessible via ECR VPC endpoint)
resource "aws_ecr_repository" "adot_collector" {
  name                 = "${var.cluster_name}/adot-collector"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = {
    Name = "${var.cluster_name}/adot-collector"
  }
}

# Lifecycle policy: keep only last 5 images per repo (cost saving)
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
