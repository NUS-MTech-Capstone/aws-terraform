
resource "aws_cognito_user_group" "admin" {
  user_pool_id = aws_cognito_user_pool.this.id
  name         = "admin"
  description  = "Admin users"
  precedence   = 1
}

resource "aws_cognito_user_group" "app_user" {
  user_pool_id = aws_cognito_user_pool.this.id
  name         = "app-user"
  description  = "Normal application users"
  precedence   = 2
}

locals {
  webapp_cognito_groups = {
    Employee        = 20
    TechnicalStaff  = 10
    Manager         = 10
    SecurityAnalyst = 10
    Auditor         = 10
    Admin           = 1
  }
}

resource "aws_cognito_user_group" "webapp" {
  for_each = local.webapp_cognito_groups

  user_pool_id = aws_cognito_user_pool.this.id
  name         = each.key
  description  = "DenDenMushi web application ${each.key} role"
  precedence   = each.value
}

resource "aws_cognito_user_pool_client" "this" {
  name         = "${var.name}-client-${var.env}"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]

  callback_urls = var.cognito_callback_urls
  logout_urls   = var.cognito_logout_urls

  supported_identity_providers = ["COGNITO"]

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH"
  ]

  read_attributes = [
    "email",
    "name",
    "custom:id",
    "custom:employee_id",
    "custom:title",
    "custom:department",
    "custom:team",
    "custom:manager",
    "custom:role",
    "custom:ssh_roles",
    "custom:access_level"
  ]

  write_attributes = [
    "email",
    "name",
    "custom:employee_id",
    "custom:title",
    "custom:department",
    "custom:team",
    "custom:manager",
    "custom:role",
    "custom:ssh_roles",
    "custom:access_level"
  ]
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.this.id
}

output "cognito_admin_group_name" {
  value = aws_cognito_user_group.admin.name
}

output "cognito_app_user_group_name" {
  value = aws_cognito_user_group.app_user.name
}

output "cognito_login_url" {
  value = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.id}.amazoncognito.com/login?client_id=${aws_cognito_user_pool_client.this.id}&response_type=code&scope=openid+email+profile&redirect_uri=${urlencode(var.cognito_callback_urls[0])}"
}
