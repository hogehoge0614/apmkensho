# ============================================================
# CloudWatch - Log Groups, Dashboard, Alarms
# ============================================================

# Log Groups with 1-day retention (cost saving)
resource "aws_cloudwatch_log_group" "eks_control_plane" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "container_insights" {
  name              = "/aws/containerinsights/${var.cluster_name}/performance"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "app_ec2" {
  name              = "/obs-poc/demo-ec2/application"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "app_fargate" {
  name              = "/obs-poc/demo-fargate/application"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "fluent_bit" {
  name              = "/aws/eks/${var.cluster_name}/fluent-bit"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "synthetics" {
  name              = "/aws/synthetics/${var.cluster_name}-canary"
  retention_in_days = 1
}

# ============================================================
# CloudWatch Dashboard
# ============================================================
resource "aws_cloudwatch_dashboard" "obs_poc" {
  dashboard_name = "${var.cluster_name}-observability-poc"

  dashboard_body = jsonencode({
    widgets = [
      # Header
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# Observability PoC Dashboard\n**Cluster:** ${var.cluster_name} | **Region:** ${var.aws_region} | **Compare:** CloudWatch Application Signals vs New Relic"
        }
      },
      # Application Signals - EC2
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Application Signals - EC2 - Latency (p99)"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["ApplicationSignals/OperationMetrics", "Latency", "Environment", "demo-ec2", "Service", "frontend-ui", { "stat" : "p99" }],
            [".", ".", ".", ".", "Service", "backend-for-frontend", { "stat" : "p99" }],
            [".", ".", ".", ".", "Service", "order-api", { "stat" : "p99" }],
            [".", ".", ".", ".", "Service", "payment-api", { "stat" : "p99" }]
          ]
        }
      },
      # Application Signals - Fargate
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Application Signals - Fargate - Latency (p99)"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["ApplicationSignals/OperationMetrics", "Latency", "Environment", "demo-fargate", "Service", "frontend-ui", { "stat" : "p99" }],
            [".", ".", ".", ".", "Service", "backend-for-frontend", { "stat" : "p99" }],
            [".", ".", ".", ".", "Service", "order-api", { "stat" : "p99" }],
            [".", ".", ".", ".", "Service", "payment-api", { "stat" : "p99" }]
          ]
        }
      },
      # Error Rate - EC2
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "Application Signals - EC2 - Error Rate"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["ApplicationSignals/OperationMetrics", "Error", "Environment", "demo-ec2", "Service", "frontend-ui"],
            [".", ".", ".", ".", "Service", "payment-api"],
            [".", ".", ".", ".", "Service", "order-api"]
          ]
        }
      },
      # Error Rate - Fargate
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "Application Signals - Fargate - Error Rate"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["ApplicationSignals/OperationMetrics", "Error", "Environment", "demo-fargate", "Service", "frontend-ui"],
            [".", ".", ".", ".", "Service", "payment-api"],
            [".", ".", ".", ".", "Service", "order-api"]
          ]
        }
      },
      # Container Insights - EC2 CPU
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 12
        height = 6
        properties = {
          title  = "Container Insights - EC2 Pod CPU Utilization"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["ContainerInsights", "pod_cpu_utilization", "ClusterName", var.cluster_name, "Namespace", "demo-ec2"]
          ]
        }
      },
      # Container Insights - Fargate Memory
      {
        type   = "metric"
        x      = 12
        y      = 14
        width  = 12
        height = 6
        properties = {
          title  = "Container Insights - Fargate Pod Memory"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["ContainerInsights", "pod_memory_utilization", "ClusterName", var.cluster_name, "Namespace", "demo-fargate"]
          ]
        }
      },
      # RUM WebVitals
      {
        type   = "metric"
        x      = 0
        y      = 20
        width  = 24
        height = 6
        properties = {
          title  = "CloudWatch RUM - Web Vitals"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["CloudWatchRUM", "RumEvent.PageView", "AppMonitorName", "${var.cluster_name}-rum"],
            [".", "RumEvent.PageViewError", "AppMonitorName", "${var.cluster_name}-rum"],
            [".", "RumEvent.JsError", "AppMonitorName", "${var.cluster_name}-rum"]
          ]
        }
      }
    ]
  })
}

# ============================================================
# CloudWatch Alarms
# ============================================================

# High Latency Alarm - EC2
resource "aws_cloudwatch_metric_alarm" "high_latency_ec2" {
  alarm_name          = "${var.cluster_name}-high-latency-ec2"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Latency"
  namespace           = "ApplicationSignals/OperationMetrics"
  period              = "60"
  extended_statistic  = "p99"
  threshold           = "2000"
  alarm_description   = "EC2 application p99 latency > 2000ms"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Environment = "demo-ec2"
  }
}

# High Error Rate Alarm - EC2
resource "aws_cloudwatch_metric_alarm" "high_error_rate_ec2" {
  alarm_name          = "${var.cluster_name}-high-error-rate-ec2"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Error"
  namespace           = "ApplicationSignals/OperationMetrics"
  period              = "60"
  statistic           = "Sum"
  threshold           = "5"
  alarm_description   = "EC2 application error count > 5 in 1 min"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Environment = "demo-ec2"
  }
}

# High Latency Alarm - Fargate
resource "aws_cloudwatch_metric_alarm" "high_latency_fargate" {
  alarm_name          = "${var.cluster_name}-high-latency-fargate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Latency"
  namespace           = "ApplicationSignals/OperationMetrics"
  period              = "60"
  extended_statistic  = "p99"
  threshold           = "2000"
  alarm_description   = "Fargate application p99 latency > 2000ms"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Environment = "demo-fargate"
  }
}

# High Error Rate Alarm - Fargate
resource "aws_cloudwatch_metric_alarm" "high_error_rate_fargate" {
  alarm_name          = "${var.cluster_name}-high-error-rate-fargate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Error"
  namespace           = "ApplicationSignals/OperationMetrics"
  period              = "60"
  statistic           = "Sum"
  threshold           = "5"
  alarm_description   = "Fargate application error count > 5 in 1 min"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Environment = "demo-fargate"
  }
}

# Pod count alarm (EC2 nodes not healthy)
resource "aws_cloudwatch_metric_alarm" "pod_cpu_ec2" {
  alarm_name          = "${var.cluster_name}-pod-cpu-high-ec2"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "pod_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = "60"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "EC2 pods CPU > 80%"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
    Namespace   = "demo-ec2"
  }
}
