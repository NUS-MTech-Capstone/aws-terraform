locals {
  ecr_repositories = toset([
    "dendenmushi/sts",
    "dendenmushi/session-manager",
    "dendenmushi/proxy-controlplane",
    "dendenmushi/proxy-dataplane",
    "dendenmushi/ddm-agent",
    "dendenmushi/agent-controlplane",
    "dendenmushi/incident-agent",
    "dendenmushi/nest-backend",
    "dendenmushi/angular",
  ])
}

resource "aws_ecr_repository" "services" {
  for_each = local.ecr_repositories

  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each = aws_ecr_repository.services

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the newest 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = {
        type = "expire"
      }
    }]
  })
}

output "ecr_repository_urls" {
  value = {
    for name, repository in aws_ecr_repository.services : name => repository.repository_url
  }
}
