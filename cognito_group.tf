
resource "aws_cognito_user_group" "admin" {
  user_pool_id = aws_cognito_user_pool.this.id
  name         = "admin"
  description  = "Admin users"
  precedence   = 1

  lifecycle {
    ignore_changes = [description]
  }
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

  lifecycle {
    ignore_changes = [description]
  }
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

resource "aws_cognito_user_pool_ui_customization" "webapp" {
  user_pool_id = aws_cognito_user_pool.this.id
  client_id    = aws_cognito_user_pool_client.this.id

  css = <<-CSS
    .background-customizable {
      background: #f5f7fb;
    }

    .banner-customizable {
      padding: 32px 0 16px;
      background: linear-gradient(135deg, #2f1f75 0%, #6f42c1 100%);
    }

    .logo-customizable {
      max-width: 220px;
    }

    .label-customizable {
      color: #1f2937;
      font-weight: 600;
    }

    .inputField-customizable {
      border: 1px solid #d9d9d9;
      border-radius: 8px;
      height: 44px;
    }

    .submitButton-customizable {
      background: #6f42c1;
      border-color: #6f42c1;
      border-radius: 8px;
      height: 44px;
      font-weight: 600;
    }

    .submitButton-customizable:hover {
      background: #58319f;
      border-color: #58319f;
    }

    .redirect-customizable {
      color: #4b5563;
    }

    .legalText-customizable {
      color: #4b5563;
    }
  CSS
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
