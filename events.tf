resource "aws_sns_topic" "ddm_events" {
  name              = "ddm-events-${var.env}"
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_sqs_queue" "ddm_audit_events_dlq" {
  name                      = "ddm-audit-events-dlq-${var.env}"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_sqs_queue" "ddm_audit_events" {
  name                       = "ddm-audit-events-${var.env}"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ddm_audit_events_dlq.arn
    maxReceiveCount     = 5
  })

  tags = {
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_sqs_queue_policy" "ddm_audit_events" {
  queue_url = aws_sqs_queue.ddm_audit_events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowDDMEventsTopic"
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.ddm_audit_events.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_sns_topic.ddm_events.arn
        }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "ddm_audit_events" {
  topic_arn = aws_sns_topic.ddm_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.ddm_audit_events.arn
}

resource "aws_iam_policy" "ddm_events_publish" {
  name = "${var.name}-events-publish-${var.env}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = aws_sns_topic.ddm_events.arn
    }]
  })
}

resource "aws_iam_policy" "audit_service_events" {
  name = "${var.name}-audit-events-${var.env}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes",
      ]
      Resource = aws_sqs_queue.ddm_audit_events.arn
    }]
  })
}

module "iam_assumable_role_sts" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.0"

  create_role                   = true
  role_name                     = "${var.name}-sts-${var.env}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [aws_iam_policy.ddm_events_publish.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:dendenmushi-ssh:sts"]
}

module "iam_assumable_role_proxy_controlplane" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.0"

  create_role                   = true
  role_name                     = "${var.name}-proxy-controlplane-${var.env}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [aws_iam_policy.ddm_events_publish.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:dendenmushi-ssh:proxy-controlplane"]
}

module "iam_assumable_role_session_manager" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.0"

  create_role                   = true
  role_name                     = "${var.name}-session-manager-${var.env}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [aws_iam_policy.ddm_events_publish.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:dendenmushi-ssh:session-manager"]
}

module "iam_assumable_role_audit_service" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "~> 5.0"

  create_role                   = true
  role_name                     = "${var.name}-audit-service-${var.env}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [aws_iam_policy.audit_service_events.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:dendenmushi-ssh:audit-service"]
}

resource "aws_iam_role_policy_attachment" "agent_controlplane_events_publish" {
  role       = module.iam_assumable_role_agent_controlplane.iam_role_name
  policy_arn = aws_iam_policy.ddm_events_publish.arn
}

output "events_topic_arn" {
  value = aws_sns_topic.ddm_events.arn
}

output "audit_events_queue_url" {
  value = aws_sqs_queue.ddm_audit_events.id
}

output "sts_role_arn" {
  value = module.iam_assumable_role_sts.iam_role_arn
}

output "proxy_controlplane_role_arn" {
  value = module.iam_assumable_role_proxy_controlplane.iam_role_arn
}

output "session_manager_role_arn" {
  value = module.iam_assumable_role_session_manager.iam_role_arn
}

output "audit_service_role_arn" {
  value = module.iam_assumable_role_audit_service.iam_role_arn
}
