locals {
  observability_namespace                  = "DenDenMushi"
  observability_cluster_name               = module.eks.cluster_name
  observability_kubernetes_namespace       = "dendenmushi"
  observability_application_alb_arn_suffix = try(data.aws_lb.application[0].arn_suffix, "")
  observability_nat_gateway_id             = try(module.vpc.natgw_ids[0], "")
  observability_target_host_namespace      = "DendenMushi/TargetHost"
  observability_target_host_id             = "host-dev-1"
  observability_target_host_environment    = var.env
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
          markdown = "# DenDenMushi observability\nLive EKS, AWS dependency, target-host, and app-level signals for demos. Request IDs are correlation-only; authorization remains ALB/Cognito plus STS."
        }
      },
      {
        type   = "text"
        x      = 0
        y      = 2
        width  = 24
        height = 1
        properties = {
          markdown = "## Platform live health"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 3
        width  = 8
        height = 6
        properties = {
          title   = "EKS Cluster Nodes"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            [{ expression = "SEARCH('{ContainerInsights,ClusterName} MetricName=\"cluster_node_count\" ClusterName=\"${local.observability_cluster_name}\"', 'Maximum', 60)", label = "Cluster node count", id = "cluster_node_count" }],
            [{ expression = "SEARCH('{ContainerInsights,ClusterName} MetricName=\"cluster_failed_node_count\" ClusterName=\"${local.observability_cluster_name}\"', 'Maximum', 60)", label = "Failed node count", id = "cluster_failed_node_count", yAxis = "right" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 3
        width  = 8
        height = 6
        properties = {
          title   = "Node Utilization"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            [{ expression = "SEARCH('{ContainerInsights,ClusterName,NodeName} MetricName=\"node_cpu_utilization\" ClusterName=\"${local.observability_cluster_name}\"', 'Average', 60)", label = "Node CPU %", id = "node_cpu_utilization" }],
            [{ expression = "SEARCH('{ContainerInsights,ClusterName,NodeName} MetricName=\"node_memory_utilization\" ClusterName=\"${local.observability_cluster_name}\"', 'Average', 60)", label = "Node memory %", id = "node_memory_utilization" }],
            [{ expression = "SEARCH('{ContainerInsights,ClusterName,NodeName} MetricName=\"node_filesystem_utilization\" ClusterName=\"${local.observability_cluster_name}\"', 'Average', 60)", label = "Node filesystem %", id = "node_filesystem_utilization" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 3
        width  = 8
        height = 6
        properties = {
          title   = "Namespace Pods"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            [{ expression = "SEARCH('{ContainerInsights,ClusterName,Namespace} MetricName=\"namespace_number_of_running_pods\" ClusterName=\"${local.observability_cluster_name}\" Namespace=\"${local.observability_kubernetes_namespace}\"', 'Average', 60)", label = "Running pods", id = "namespace_running_pods" }],
            [{ expression = "SEARCH('{ContainerInsights,ClusterName,Namespace} MetricName=\"namespace_number_of_pods\" ClusterName=\"${local.observability_cluster_name}\" Namespace=\"${local.observability_kubernetes_namespace}\"', 'Average', 60)", label = "Total pods", id = "namespace_total_pods" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 8
        height = 6
        properties = {
          title   = "Application Pod CPU"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            [{ expression = "SEARCH('{ContainerInsights,ClusterName,Namespace,PodName} MetricName=\"pod_cpu_utilization\" ClusterName=\"${local.observability_cluster_name}\" Namespace=\"${local.observability_kubernetes_namespace}\"', 'Average', 60)", label = "Pod CPU %", id = "pod_cpu_utilization" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 9
        width  = 8
        height = 6
        properties = {
          title   = "Application Pod Memory"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            [{ expression = "SEARCH('{ContainerInsights,ClusterName,Namespace,PodName} MetricName=\"pod_memory_utilization\" ClusterName=\"${local.observability_cluster_name}\" Namespace=\"${local.observability_kubernetes_namespace}\"', 'Average', 60)", label = "Pod memory %", id = "pod_memory_utilization" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 9
        width  = 8
        height = 6
        properties = {
          title   = "Pod Restarts And Network"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            [{ expression = "SEARCH('{ContainerInsights,ClusterName,Namespace,PodName} MetricName=\"pod_number_of_container_restarts\" ClusterName=\"${local.observability_cluster_name}\" Namespace=\"${local.observability_kubernetes_namespace}\"', 'Sum', 60)", label = "Container restarts", id = "pod_restarts", yAxis = "right" }],
            [{ expression = "SEARCH('{ContainerInsights,ClusterName,Namespace,PodName} MetricName=\"pod_network_rx_bytes\" ClusterName=\"${local.observability_cluster_name}\" Namespace=\"${local.observability_kubernetes_namespace}\"', 'Sum', 60)", label = "Pod network RX bytes", id = "pod_network_rx_bytes" }],
            [{ expression = "SEARCH('{ContainerInsights,ClusterName,Namespace,PodName} MetricName=\"pod_network_tx_bytes\" ClusterName=\"${local.observability_cluster_name}\" Namespace=\"${local.observability_kubernetes_namespace}\"', 'Sum', 60)", label = "Pod network TX bytes", id = "pod_network_tx_bytes" }],
          ]
        }
      },
      {
        type   = "text"
        x      = 0
        y      = 15
        width  = 24
        height = 1
        properties = {
          markdown = "## AWS dependencies and target host demo signals"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 16
        width  = 8
        height = 6
        properties = {
          title   = "ALB Traffic And Errors"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.observability_application_alb_arn_suffix, { stat = "Sum", label = "Requests" }],
            [".", "HTTPCode_Target_4XX_Count", ".", ".", { stat = "Sum", yAxis = "right", label = "Target 4xx" }],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", { stat = "Sum", yAxis = "right", label = "Target 5xx" }],
            [".", "TargetResponseTime", ".", ".", { stat = "p95", label = "Target response p95" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 16
        width  = 8
        height = 6
        properties = {
          title   = "ALB Target Health"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", local.observability_application_alb_arn_suffix, { stat = "Minimum", label = "Healthy targets" }],
            [".", "UnHealthyHostCount", ".", ".", { stat = "Maximum", label = "Unhealthy targets" }],
            [".", "ActiveConnectionCount", ".", ".", { stat = "Sum", yAxis = "right", label = "Active connections" }],
            [".", "NewConnectionCount", ".", ".", { stat = "Sum", yAxis = "right", label = "New connections" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 16
        width  = 8
        height = 6
        properties = {
          title   = "RDS PostgreSQL"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.postgres.identifier, { stat = "Average", label = "CPU %" }],
            [".", "DatabaseConnections", ".", ".", { stat = "Average", yAxis = "right", label = "DB connections" }],
            [".", "FreeStorageSpace", ".", ".", { stat = "Minimum", label = "Free storage bytes" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 22
        width  = 8
        height = 6
        properties = {
          title   = "RDS I/O"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", aws_db_instance.postgres.identifier, { stat = "Average", label = "Read IOPS" }],
            [".", "WriteIOPS", ".", ".", { stat = "Average", label = "Write IOPS" }],
            [".", "ReadLatency", ".", ".", { stat = "Average", yAxis = "right", label = "Read latency" }],
            [".", "WriteLatency", ".", ".", { stat = "Average", yAxis = "right", label = "Write latency" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 22
        width  = 8
        height = 6
        properties = {
          title   = "NAT Gateway"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/NATGateway", "BytesInFromSource", "NatGatewayId", local.observability_nat_gateway_id, { stat = "Sum", label = "Bytes in from workloads" }],
            [".", "BytesOutToDestination", ".", ".", { stat = "Sum", label = "Bytes out to internet" }],
            [".", "PacketsDropCount", ".", ".", { stat = "Sum", yAxis = "right", label = "Packets dropped" }],
            [".", "ErrorPortAllocation", ".", ".", { stat = "Sum", yAxis = "right", label = "Port allocation errors" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 22
        width  = 8
        height = 6
        properties = {
          title   = "Incident Alert Queue"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.incident_alerts.name, { stat = "Maximum", label = "Visible messages" }],
            [".", "ApproximateAgeOfOldestMessage", ".", ".", { stat = "Maximum", label = "Oldest message age seconds" }],
            [".", "NumberOfMessagesReceived", ".", ".", { stat = "Sum", yAxis = "right", label = "Messages received" }],
            [".", "NumberOfMessagesDeleted", ".", ".", { stat = "Sum", yAxis = "right", label = "Messages deleted" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 28
        width  = 8
        height = 6
        properties = {
          title   = "Target Host CPU And Memory"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            [{ expression = "100 - AVG(SEARCH('{${local.observability_target_host_namespace},Environment,HostId,cpu} MetricName=\"cpu_usage_idle\" Environment=\"${local.observability_target_host_environment}\" HostId=\"${local.observability_target_host_id}\" cpu=\"cpu-total\"', 'Average', 60))", label = "CPU active %", id = "target_cpu_active" }],
            [{ expression = "SEARCH('{${local.observability_target_host_namespace},Environment,HostId} MetricName=\"mem_used_percent\" Environment=\"${local.observability_target_host_environment}\" HostId=\"${local.observability_target_host_id}\"', 'Average', 60)", label = "Memory used %", id = "target_memory_used" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 28
        width  = 8
        height = 6
        properties = {
          title   = "Target Host Disk And Swap"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            [{ expression = "SEARCH('{${local.observability_target_host_namespace},Environment,HostId,path} MetricName=\"used_percent\" Environment=\"${local.observability_target_host_environment}\" HostId=\"${local.observability_target_host_id}\" path=\"/\"', 'Average', 60)", label = "Root disk used %", id = "target_disk_used" }],
            [{ expression = "SEARCH('{${local.observability_target_host_namespace},Environment,HostId} MetricName=\"swap_used_percent\" Environment=\"${local.observability_target_host_environment}\" HostId=\"${local.observability_target_host_id}\"', 'Average', 60)", label = "Swap used %", id = "target_swap_used" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 28
        width  = 8
        height = 6
        properties = {
          title   = "Target Demo App Health"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = "Sum"
          metrics = [
            [{ expression = "SEARCH('{${local.observability_target_host_namespace}} MetricName=\"dendenmushi-target-${local.observability_target_host_id}-${local.observability_target_host_environment}-demo-app-unhealthy\"', 'Sum', 60)", label = "Demo app unhealthy events", id = "target_demo_unhealthy" }],
          ]
        }
      },
      {
        type   = "text"
        x      = 0
        y      = 34
        width  = 24
        height = 1
        properties = {
          markdown = "## DenDenMushi app signals"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 35
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
        y      = 35
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
        y      = 35
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
        y      = 41
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
        y      = 41
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
        y      = 41
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
        y      = 47
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
        y      = 53
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
