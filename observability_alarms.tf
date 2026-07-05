locals {
  observability_namespace = "DenDenMushi"
  observability_alarm_actions = [
    aws_sns_topic.incident_alerts.arn,
  ]
  observability_common_alarm_tags = {
    Environment = var.env
    Project     = var.name
    ManagedBy   = "terraform"
  }
}

resource "aws_cloudwatch_dashboard" "application_observability" {
  dashboard_name = "${var.name}-${var.env}-application-observability"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# DenDenMushi application observability\nApp-level EMF metrics from STS, Proxy Control Plane, Session Manager, Proxy Dataplane, Nest Backend, and Incident Agent. Request IDs are correlation-only; authorization remains ALB/Cognito plus STS."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 8
        height = 6
        properties = {
          title   = "Session Health"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Sum"
          metrics = [
            [local.observability_namespace, "SessionStartFailures", "Service", "proxy-controlplane", "Environment", var.env, { label = "Session start failures" }],
            [".", "AssignmentFailures", ".", "session-manager", ".", ".", { label = "Assignment failures" }],
            [".", "SSHFailures", ".", "proxy-dataplane", ".", ".", { label = "SSH failures" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 2
        width  = 8
        height = 6
        properties = {
          title   = "STS Dependency"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            [local.observability_namespace, "STSRequestLatencyMs", "Service", "proxy-controlplane", "Environment", var.env, { stat = "p95", label = "Control plane STS p95 latency" }],
            [".", ".", ".", "proxy-dataplane", ".", ".", { stat = "p95", label = "Dataplane STS p95 latency" }],
            [".", "STSErrors", ".", "proxy-controlplane", ".", ".", { stat = "Sum", yAxis = "right", label = "Control plane STS errors" }],
            [".", ".", ".", "proxy-dataplane", ".", ".", { stat = "Sum", yAxis = "right", label = "Dataplane STS errors" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 2
        width  = 8
        height = 6
        properties = {
          title   = "Authentication Failures"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Sum"
          metrics = [
            [local.observability_namespace, "AuthFailures", "Service", "sts", "Environment", var.env, { label = "STS auth failures" }],
            [".", ".", ".", "nest-backend", ".", ".", { label = "Nest auth failures" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 8
        height = 6
        properties = {
          title   = "Proxy Capacity"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            [local.observability_namespace, "ActiveSessions", "Service", "session-manager", "Environment", var.env, { stat = "Maximum", label = "Active sessions" }],
            [".", "ProxyPodCapacity", ".", ".", ".", ".", { stat = "Minimum", label = "Available session capacity" }],
            [".", "AvailableProxyPods", ".", ".", ".", ".", { stat = "Minimum", yAxis = "right", label = "Available proxy pods" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 8
        width  = 8
        height = 6
        properties = {
          title   = "Heartbeat And Pod Health"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Sum"
          metrics = [
            [local.observability_namespace, "HeartbeatMisses", "Service", "proxy-dataplane", "Environment", var.env, { label = "Dataplane heartbeat misses" }],
            [".", ".", ".", "session-manager", ".", ".", { label = "Session manager heartbeat misses" }],
            [".", "StaleProxyPods", ".", "session-manager", ".", ".", { label = "Stale proxy pods" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 8
        width  = 8
        height = 6
        properties = {
          title   = "WebSocket Disconnects"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Sum"
          metrics = [
            [local.observability_namespace, "WebSocketDisconnects", "Service", "proxy-dataplane", "Environment", var.env, { label = "All disconnects" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 24
        height = 6
        properties = {
          title   = "Incident Agent"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            [local.observability_namespace, "IncidentReceived", "Service", "incident-agent", "Environment", var.env, { stat = "Sum", label = "Incidents received" }],
            [".", "PlanApproved", ".", ".", ".", ".", { stat = "Sum", label = "Plans approved" }],
            [".", "RemediationExecuted", ".", ".", ".", ".", { stat = "Sum", label = "Remediations executed" }],
            [".", "RemediationFailed", ".", ".", ".", ".", { stat = "Sum", yAxis = "right", label = "Remediation failures" }],
            [".", "SQSMessageFailures", ".", ".", ".", ".", { stat = "Sum", yAxis = "right", label = "SQS failures" }],
            [".", "BedrockErrors", ".", ".", ".", ".", { stat = "Sum", yAxis = "right", label = "Bedrock errors" }],
            [".", "BedrockRequestLatencyMs", ".", ".", ".", ".", { stat = "p95", label = "Bedrock p95 latency" }],
          ]
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 20
        width  = 24
        height = 6
        properties = {
          title = "Operational Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.high_auth_failure_rate.arn,
            aws_cloudwatch_metric_alarm.sts_unavailable.arn,
            aws_cloudwatch_metric_alarm.high_sts_latency.arn,
            aws_cloudwatch_metric_alarm.session_start_failures.arn,
            aws_cloudwatch_metric_alarm.assignment_failures.arn,
            aws_cloudwatch_metric_alarm.proxy_pod_unhealthy.arn,
            aws_cloudwatch_metric_alarm.heartbeat_misses.arn,
            aws_cloudwatch_metric_alarm.websocket_disconnect_errors.arn,
            aws_cloudwatch_metric_alarm.ssh_failures.arn,
            aws_cloudwatch_metric_alarm.proxy_pod_capacity_low.arn,
            aws_cloudwatch_metric_alarm.incident_agent_remediation_failures.arn,
            aws_cloudwatch_metric_alarm.incident_agent_sqs_failures.arn,
            aws_cloudwatch_metric_alarm.incident_agent_bedrock_errors.arn,
          ]
        }
      },
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "high_auth_failure_rate" {
  alarm_name          = "${var.name}-${var.env}-high-auth-failure-rate"
  alarm_description   = jsonencode({ event = "HighAuthFailureRate", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "AuthFailures"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "sts"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "sts_unavailable" {
  alarm_name          = "${var.name}-${var.env}-sts-unavailable"
  alarm_description   = jsonencode({ event = "STSUnavailable", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "STSErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "proxy-controlplane"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "high_sts_latency" {
  alarm_name          = "${var.name}-${var.env}-high-sts-latency"
  alarm_description   = jsonencode({ event = "HighSTSLatency", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "STSRequestLatencyMs"
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1000
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "proxy-controlplane"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "session_start_failures" {
  alarm_name          = "${var.name}-${var.env}-session-start-failures"
  alarm_description   = jsonencode({ event = "SessionStartFailed", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "SessionStartFailures"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "proxy-controlplane"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "assignment_failures" {
  alarm_name          = "${var.name}-${var.env}-assignment-failures"
  alarm_description   = jsonencode({ event = "AssignmentFailures", windowSeconds = 600 })
  namespace           = local.observability_namespace
  metric_name         = "AssignmentFailures"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "session-manager"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "proxy_pod_unhealthy" {
  alarm_name          = "${var.name}-${var.env}-proxy-pod-unhealthy"
  alarm_description   = jsonencode({ event = "ProxyPodUnhealthy", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "StaleProxyPods"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "session-manager"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "heartbeat_misses" {
  alarm_name          = "${var.name}-${var.env}-heartbeat-misses"
  alarm_description   = jsonencode({ event = "HeartbeatMisses", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "HeartbeatMisses"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "proxy-dataplane"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "websocket_disconnect_errors" {
  alarm_name          = "${var.name}-${var.env}-websocket-disconnect-errors"
  alarm_description   = jsonencode({ event = "WebSocketDisconnectErrors", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "WebSocketDisconnects"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "proxy-dataplane"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "ssh_failures" {
  alarm_name          = "${var.name}-${var.env}-ssh-failures"
  alarm_description   = jsonencode({ event = "SSHFailures", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "SSHFailures"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "proxy-dataplane"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "proxy_pod_capacity_low" {
  alarm_name          = "${var.name}-${var.env}-proxy-pod-capacity-low"
  alarm_description   = jsonencode({ event = "ProxyPodCapacityLow", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "ProxyPodCapacity"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "session-manager"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "incident_agent_remediation_failures" {
  alarm_name          = "${var.name}-${var.env}-incident-agent-remediation-failures"
  alarm_description   = jsonencode({ event = "RemediationFailed", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "RemediationFailed"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "incident-agent"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "incident_agent_sqs_failures" {
  alarm_name          = "${var.name}-${var.env}-incident-agent-sqs-failures"
  alarm_description   = jsonencode({ event = "SQSMessageFailures", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "SQSMessageFailures"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "incident-agent"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "incident_agent_bedrock_errors" {
  alarm_name          = "${var.name}-${var.env}-incident-agent-bedrock-errors"
  alarm_description   = jsonencode({ event = "BedrockErrors", windowSeconds = 300 })
  namespace           = local.observability_namespace
  metric_name         = "BedrockErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.observability_alarm_actions
  ok_actions          = local.observability_alarm_actions

  dimensions = {
    Service     = "incident-agent"
    Environment = var.env
  }

  tags = local.observability_common_alarm_tags
}

output "application_observability_dashboard_name" {
  description = "CloudWatch dashboard name for DenDenMushi app-level metrics."
  value       = aws_cloudwatch_dashboard.application_observability.dashboard_name
}
