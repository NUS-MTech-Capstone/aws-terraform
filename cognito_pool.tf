resource "aws_cognito_user_pool" "this" {
  name                = "${var.name}-user-pool-${var.env}"
  username_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = false
    require_numbers   = false
    require_symbols   = false
    require_uppercase = false
  }

  auto_verified_attributes = ["email"]

  schema {
    attribute_data_type = "String"
    name                = "name"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 128
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "id"
    required            = false
    mutable             = false
    string_attribute_constraints {
      min_length = 1
      max_length = 64
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "employee_id"
    required            = false
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 64
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "title"
    required            = false
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 128
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "department"
    required            = false
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 128
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "team"
    required            = false
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 128
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "manager"
    required            = false
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 128
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "role"
    required            = false
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 128
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "ssh_roles"
    required            = false
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 2048
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "access_level"
    required            = false
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 64
    }
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "DenDenMushi - Verify your email"
    email_message        = "Your verification code is {####}"
  }

  mfa_configuration = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  tags = {
    Environment = var.env
    ManagedBy   = "terraform"
  }
}


resource "aws_cognito_user_pool_domain" "this" {
  domain                = var.cognito_domain_prefix
  user_pool_id          = aws_cognito_user_pool.this.id
  managed_login_version = 2
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_user_pool_arn" {
  value = aws_cognito_user_pool.this.arn
}

output "cognito_domain" {
  value = aws_cognito_user_pool_domain.this.domain
}
