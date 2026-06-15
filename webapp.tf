locals {
  webapp_database_name     = "ddm_webapp"
  webapp_database_username = "ddm_webapp"
}

resource "random_password" "webapp_database" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "webapp_database_url" {
  name                    = "${var.name}/nest-backend/database-url-${var.env}"
  recovery_window_in_days = 0

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_secretsmanager_secret_version" "webapp_database_url" {
  secret_id = aws_secretsmanager_secret.webapp_database_url.id
  secret_string = format(
    "postgres://%s:%s@%s:%d/%s?sslmode=require",
    local.webapp_database_username,
    urlencode(random_password.webapp_database.result),
    aws_db_instance.postgres.address,
    aws_db_instance.postgres.port,
    local.webapp_database_name,
  )
}

resource "aws_secretsmanager_secret" "webapp_database_bootstrap" {
  name                    = "${var.name}/nest-backend/database-bootstrap-${var.env}"
  recovery_window_in_days = 0

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_secretsmanager_secret_version" "webapp_database_bootstrap" {
  secret_id = aws_secretsmanager_secret.webapp_database_bootstrap.id
  secret_string = jsonencode({
    databaseName = local.webapp_database_name
    username     = local.webapp_database_username
    password     = random_password.webapp_database.result
  })
}

resource "aws_iam_policy" "nest_backend" {
  name = "${var.name}-nest-backend-${var.env}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cognito-idp:ListUsers",
        "cognito-idp:AdminListGroupsForUser",
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminAddUserToGroup",
        "cognito-idp:AdminRemoveUserFromGroup",
        "cognito-idp:AdminEnableUser",
        "cognito-idp:AdminDisableUser",
      ]
      Resource = aws_cognito_user_pool.this.arn
    }]
  })
}

module "iam_assumable_role_nest_backend" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.0"

  create_role                   = true
  role_name                     = "${var.name}-nest-backend-${var.env}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [aws_iam_policy.nest_backend.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:dendenmushi:nest-backend"]
}

output "nest_backend_role_arn" {
  value = module.iam_assumable_role_nest_backend.iam_role_arn
}

output "webapp_database_secret_id" {
  value = aws_secretsmanager_secret.webapp_database_url.id
}

output "webapp_database_bootstrap_secret_id" {
  value = aws_secretsmanager_secret.webapp_database_bootstrap.id
}
