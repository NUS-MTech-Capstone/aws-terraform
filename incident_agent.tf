resource "aws_kms_key" "incident_alerts_sns" {
  description             = "Encrypts Incident Agent SNS alarm notifications."
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchAlarmsPublish"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_kms_alias" "incident_alerts_sns" {
  name          = "alias/${var.name}-incident-alerts-sns-${var.env}"
  target_key_id = aws_kms_key.incident_alerts_sns.key_id
}

resource "aws_sns_topic" "incident_alerts" {
  name              = "${var.name}-incident-alerts-${var.env}"
  kms_master_key_id = aws_kms_key.incident_alerts_sns.arn

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_sns_topic_policy" "incident_alerts" {
  arn = aws_sns_topic.incident_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "OwnerAdministration"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action = [
          "SNS:AddPermission",
          "SNS:DeleteTopic",
          "SNS:GetTopicAttributes",
          "SNS:ListSubscriptionsByTopic",
          "SNS:Publish",
          "SNS:Receive",
          "SNS:RemovePermission",
          "SNS:SetTopicAttributes",
          "SNS:Subscribe",
        ]
        Resource = aws_sns_topic.incident_alerts.arn
        Condition = {
          StringEquals = {
            "AWS:SourceOwner" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.incident_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}

resource "aws_sqs_queue" "incident_alerts_dlq" {
  name                      = "${var.name}-incident-alerts-dlq-${var.env}"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_sqs_queue" "incident_alerts" {
  name                       = "${var.name}-incident-alerts-${var.env}"
  visibility_timeout_seconds = 600
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.incident_alerts_dlq.arn
    maxReceiveCount     = 5
  })

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_sqs_queue_policy" "incident_alerts" {
  queue_url = aws_sqs_queue.incident_alerts.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowIncidentSNSTopic"
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.incident_alerts.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_sns_topic.incident_alerts.arn
        }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "incident_alerts" {
  topic_arn = aws_sns_topic.incident_alerts.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.incident_alerts.arn
}

resource "aws_secretsmanager_secret" "incident_database_url" {
  name                    = "${var.name}/incident-agent/database-url-${var.env}"
  recovery_window_in_days = 0

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_secretsmanager_secret_version" "incident_database_url" {
  secret_id = aws_secretsmanager_secret.incident_database_url.id
  secret_string = format(
    "postgres://%s:%s@%s:%d/%s?sslmode=require",
    urlencode(var.postgres_db_username),
    urlencode(var.postgres_db_password),
    aws_db_instance.postgres.address,
    aws_db_instance.postgres.port,
    aws_db_instance.postgres.db_name,
  )
}

locals {
  incident_agent_langsmith_project = var.langsmith_project != "" ? var.langsmith_project : "${var.name}-incident-agent-${var.env}"
}

resource "aws_secretsmanager_secret" "incident_agent_langsmith_api_key" {
  name                    = "${var.name}/incident-agent/langsmith-api-key-${var.env}"
  recovery_window_in_days = 0

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_secretsmanager_secret_version" "incident_agent_langsmith_api_key" {
  count         = trimspace(nonsensitive(var.langsmith_api_key)) == "" ? 0 : 1
  secret_id     = aws_secretsmanager_secret.incident_agent_langsmith_api_key.id
  secret_string = trimspace(var.langsmith_api_key)
}

# This secret intentionally has no Terraform-managed value. Populate it through
# Secrets Manager after creating a project-scoped OpenAI key, then let AgentCore
# Identity reference the secret so the EKS workload never receives the key.
resource "aws_secretsmanager_secret" "incident_agent_openai_api_key" {
  name                    = "${var.name}/incident-agent/openai-api-key-${var.env}"
  description             = "OpenAI API key reserved for the AgentCore inference gateway."
  recovery_window_in_days = 7

  tags = {
    Environment = var.env
    Project     = var.name
    Purpose     = "agentcore-openai-inference"
  }
}

resource "aws_iam_policy" "incident_agent" {
  name = "${var.name}-incident-agent-${var.env}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.incident_alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.incident_database_url.arn
      },
    ]
  })
}

module "iam_assumable_role_incident_agent" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.0"

  create_role                   = true
  role_name                     = "${var.name}-incident-agent-${var.env}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [aws_iam_policy.incident_agent.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:dendenmushi-agentic:incident-agent"]
}

output "incident_agent_role_arn" {
  value = module.iam_assumable_role_incident_agent.iam_role_arn
}

resource "aws_iam_policy" "incident_reasoning_agent" {
  name = "${var.name}-incident-reasoning-agent-${var.env}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.incident_agent_langsmith_api_key.arn
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:InvokeGateway"]
        Resource = aws_cloudformation_stack.agentcore_openai_gateway.outputs["GatewayArn"]
      },
    ]
  })
}

module "iam_assumable_role_incident_reasoning_agent" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.0"

  create_role                   = true
  role_name                     = "${var.name}-incident-reasoning-agent-${var.env}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [aws_iam_policy.incident_reasoning_agent.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:dendenmushi-agentic:incident-reasoning-agent"]
}

output "incident_reasoning_agent_role_arn" {
  value = module.iam_assumable_role_incident_reasoning_agent.iam_role_arn
}

resource "aws_iam_policy" "agent_controlplane" {
  name = "${var.name}-agent-controlplane-${var.env}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.incident_database_url.arn
      },
    ]
  })
}

module "iam_assumable_role_agent_controlplane" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.0"

  create_role                   = true
  role_name                     = "${var.name}-agent-controlplane-${var.env}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [aws_iam_policy.agent_controlplane.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:dendenmushi-agentic:agent-controlplane"]
}

output "agent_controlplane_role_arn" {
  value = module.iam_assumable_role_agent_controlplane.iam_role_arn
}

output "incident_alerts_topic_arn" {
  value = aws_sns_topic.incident_alerts.arn
}

output "incident_alerts_queue_url" {
  value = aws_sqs_queue.incident_alerts.id
}

output "incident_database_secret_id" {
  value = aws_secretsmanager_secret.incident_database_url.id
}

output "incident_agent_langsmith_api_key_secret_id" {
  value = aws_secretsmanager_secret.incident_agent_langsmith_api_key.id
}

output "incident_agent_openai_api_key_secret_id" {
  description = "Secrets Manager secret to populate with a JSON api_key field before enabling the AgentCore OpenAI target."
  value       = aws_secretsmanager_secret.incident_agent_openai_api_key.id
}

output "incident_agent_langsmith_project" {
  value = local.incident_agent_langsmith_project
}

output "incident_agent_langsmith_endpoint" {
  value = var.langsmith_endpoint
}

output "incident_agent_langsmith_workspace_id" {
  value = var.langsmith_workspace_id
}
