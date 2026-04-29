# ============================================================
# New Relic AWS Integration
# - CloudWatch Metric Streams → Kinesis Firehose → New Relic
# - IAM Role for New Relic to poll AWS APIs
# ============================================================

# S3 bucket for Firehose backup (failed deliveries)
resource "aws_s3_bucket" "firehose_backup" {
  count         = var.new_relic_metric_stream_enabled ? 1 : 0
  bucket        = "${var.cluster_name}-firehose-backup-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "firehose_backup" {
  count  = var.new_relic_metric_stream_enabled ? 1 : 0
  bucket = aws_s3_bucket.firehose_backup[0].id

  rule {
    id     = "expire-failed-metrics"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }
  }
}

# Kinesis Firehose Delivery Stream → New Relic Metric API
resource "aws_kinesis_firehose_delivery_stream" "newrelic_metrics" {
  count       = var.new_relic_metric_stream_enabled ? 1 : 0
  name        = "${var.cluster_name}-newrelic-metrics"
  destination = "http_endpoint"

  http_endpoint_configuration {
    url                = "https://aws-api.newrelic.com/cloudwatch-metrics/v1"
    name               = "New Relic"
    access_key         = var.new_relic_license_key
    buffering_size     = 1
    buffering_interval = 60
    role_arn           = aws_iam_role.firehose.arn
    retry_duration     = 60
    s3_backup_mode     = "FailedDataOnly"

    request_configuration {
      content_encoding = "GZIP"
    }

    s3_configuration {
      role_arn           = aws_iam_role.firehose.arn
      bucket_arn         = aws_s3_bucket.firehose_backup[0].arn
      buffering_size     = 10
      buffering_interval = 400
      compression_format = "GZIP"
    }
  }
}

# CloudWatch Metric Stream → Firehose
resource "aws_cloudwatch_metric_stream" "newrelic" {
  count = var.new_relic_metric_stream_enabled ? 1 : 0

  name          = "${var.cluster_name}-newrelic-stream"
  role_arn      = aws_iam_role.metric_stream.arn
  firehose_arn  = aws_kinesis_firehose_delivery_stream.newrelic_metrics[0].arn
  output_format = "opentelemetry0.7"

  # Stream key namespaces for EKS/Container Insights comparison
  include_filter {
    namespace    = "ContainerInsights"
    metric_names = []
  }
  include_filter {
    namespace    = "ApplicationSignals/OperationMetrics"
    metric_names = []
  }
  include_filter {
    namespace    = "AWS/EKS"
    metric_names = []
  }
  include_filter {
    namespace    = "AWS/EC2"
    metric_names = ["CPUUtilization", "NetworkIn", "NetworkOut"]
  }
  include_filter {
    namespace    = "CloudWatchRUM"
    metric_names = []
  }
}
