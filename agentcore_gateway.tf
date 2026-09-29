locals {
  agentcore_gateway_name              = "${var.name}-openai-${var.env}"
  agentcore_token_vault               = "arn:aws:bedrock-agentcore:${var.aws_region}:${data.aws_caller_identity.current.account_id}:token-vault/default"
  agentcore_workload_directory        = "arn:aws:bedrock-agentcore:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default"
  agentcore_gateway_workload_identity = "arn:aws:bedrock-agentcore:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default/workload-identity/${local.agentcore_gateway_name}-*"
}

# The pinned AWS provider does not yet expose AgentCore external-secret API key
# providers or inference connector targets. Keep these two narrow resources in
# CloudFormation until the provider supports the same fields without importing
# the OpenAI key into Terraform state.
resource "aws_cloudformation_stack" "agentcore_openai_credential" {
  name = "${var.name}-agentcore-openai-credential-${var.env}"

  parameters = {
    SecretId = aws_secretsmanager_secret.incident_agent_openai_api_key.arn
  }

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "AgentCore external-secret credential provider for DenDenMushi OpenAI inference."
    Parameters = {
      SecretId = { Type = "String" }
    }
    Resources = {
      OpenAICredential = {
        Type = "AWS::BedrockAgentCore::ApiKeyCredentialProvider"
        Properties = {
          Name               = replace("${var.name}_openai_${var.env}", "-", "_")
          ApiKeySecretSource = "EXTERNAL"
          ApiKeySecretConfig = {
            SecretId = { Ref = "SecretId" }
            JsonKey  = "api_key"
          }
          Tags = [
            { Key = "Environment", Value = var.env },
            { Key = "Project", Value = var.name },
            { Key = "Purpose", Value = "agentcore-openai-inference" },
          ]
        }
      }
    }
    Outputs = {
      CredentialProviderArn = {
        Value = { "Fn::GetAtt" = ["OpenAICredential", "CredentialProviderArn"] }
      }
    }
  })

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_iam_role" "agentcore_gateway_execution" {
  name = "${var.name}-agentcore-gateway-${var.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "bedrock-agentcore.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:bedrock-agentcore:${var.aws_region}:${data.aws_caller_identity.current.account_id}:gateway/${local.agentcore_gateway_name}-*"
        }
      }
    }]
  })

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_iam_policy" "agentcore_gateway_execution" {
  name = "${var.name}-agentcore-gateway-${var.env}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetGatewayWorkloadToken"
        Effect = "Allow"
        Action = ["bedrock-agentcore:GetWorkloadAccessToken"]
        Resource = [
          local.agentcore_workload_directory,
          local.agentcore_gateway_workload_identity,
        ]
      },
      {
        Sid    = "GetOpenAICredential"
        Effect = "Allow"
        Action = ["bedrock-agentcore:GetResourceApiKey"]
        Resource = [
          aws_cloudformation_stack.agentcore_openai_credential.outputs["CredentialProviderArn"],
          local.agentcore_token_vault,
          local.agentcore_workload_directory,
          local.agentcore_gateway_workload_identity,
        ]
      },
      {
        Sid    = "DenyOtherGatewayCredentials"
        Effect = "Deny"
        Action = ["bedrock-agentcore:GetResourceApiKey"]
        NotResource = [
          aws_cloudformation_stack.agentcore_openai_credential.outputs["CredentialProviderArn"],
          local.agentcore_token_vault,
          local.agentcore_workload_directory,
          local.agentcore_gateway_workload_identity,
        ]
      },
      {
        Sid      = "ReadOpenAISecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.incident_agent_openai_api_key.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "agentcore_gateway_execution" {
  role       = aws_iam_role.agentcore_gateway_execution.name
  policy_arn = aws_iam_policy.agentcore_gateway_execution.arn
}

resource "aws_cloudformation_stack" "agentcore_openai_gateway" {
  name = "${var.name}-agentcore-openai-gateway-${var.env}"

  parameters = {
    CredentialProviderArn = aws_cloudformation_stack.agentcore_openai_credential.outputs["CredentialProviderArn"]
    GatewayRoleArn        = aws_iam_role.agentcore_gateway_execution.arn
  }

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "IAM-authenticated AgentCore gateway for DenDenMushi OpenAI inference."
    Parameters = {
      CredentialProviderArn = { Type = "String" }
      GatewayRoleArn        = { Type = "String" }
    }
    Resources = {
      Gateway = {
        Type = "AWS::BedrockAgentCore::Gateway"
        Properties = {
          Name           = local.agentcore_gateway_name
          Description    = "OpenAI inference only; the existing MCP Tool Gateway is unchanged."
          AuthorizerType = "AWS_IAM"
          ProtocolType   = "MCP"
          RoleArn        = { Ref = "GatewayRoleArn" }
          Tags = {
            Environment = var.env
            Project     = var.name
            Purpose     = "openai-inference"
          }
        }
      }
      OpenAITarget = {
        Type = "AWS::BedrockAgentCore::GatewayTarget"
        Properties = {
          GatewayIdentifier = { Ref = "Gateway" }
          Name              = "openai"
          Description       = "Built-in OpenAI Responses API inference connector."
          TargetConfiguration = {
            Inference = {
              Connector = {
                Source = { ConnectorId = "openai" }
              }
            }
          }
          CredentialProviderConfigurations = [{
            CredentialProviderType = "API_KEY"
            CredentialProvider = {
              ApiKeyCredentialProvider = {
                ProviderArn             = { Ref = "CredentialProviderArn" }
                CredentialLocation      = "HEADER"
                CredentialParameterName = "Authorization"
                CredentialPrefix        = "Bearer "
              }
            }
          }]
        }
      }
      OpenAITargetRateLimit = {
        Type      = "AWS::BedrockAgentCore::GatewayRateLimit"
        DependsOn = "OpenAITarget"
        Properties = {
          GatewayIdentifier = { Ref = "Gateway" }
          RateLimitId       = "openai-target-limit"
          Description       = "Fail-open spike limit for the OpenAI inference connector."
          DimensionKeys     = ["targetName"]
          Entries = [{
            Dimensions = { targetName = "openai" }
            Requests   = [{ Rate = 10, Period = "minute" }]
            Tokens     = [{ Rate = 100000, Period = "minute" }]
          }]
        }
      }
    }
    Outputs = {
      GatewayArn        = { Value = { "Fn::GetAtt" = ["Gateway", "GatewayArn"] } }
      GatewayIdentifier = { Value = { Ref = "Gateway" } }
      GatewayUrl        = { Value = { "Fn::GetAtt" = ["Gateway", "GatewayUrl"] } }
      OpenAITargetId    = { Value = { "Fn::GetAtt" = ["OpenAITarget", "TargetId"] } }
    }
  })

  depends_on = [aws_iam_role_policy_attachment.agentcore_gateway_execution]

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

output "agentcore_openai_gateway_arn" {
  description = "ARN of the IAM-authenticated AgentCore OpenAI inference gateway."
  value       = aws_cloudformation_stack.agentcore_openai_gateway.outputs["GatewayArn"]
}

output "agentcore_openai_gateway_url" {
  description = "Base URL of the AgentCore OpenAI inference gateway."
  value       = aws_cloudformation_stack.agentcore_openai_gateway.outputs["GatewayUrl"]
}

output "agentcore_openai_gateway_target_id" {
  description = "AgentCore built-in OpenAI inference connector target ID."
  value       = aws_cloudformation_stack.agentcore_openai_gateway.outputs["OpenAITargetId"]
}
