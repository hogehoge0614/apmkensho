# ============================================================
# CloudWatch Logs → New Relic forwarder (agentless, no Lambda)
#
# CW Logs subscription filter → Kinesis Firehose → NR Log API
# Filtering (ERROR/CRITICAL/FATAL) is done at the subscription
# filter level — no code required.
#
# Enable with: cw_to_newrelic_enabled = true
# ============================================================

# ---- S3 backup for Firehose failed deliveries only --------------------------

resource "aws_s3_bucket" "cw_to_nr_backup" {
  count         = var.cw_to_newrelic_enabled ? 1 : 0
  bucket        = "${var.cluster_name}-cw-nr-backup-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cw_to_nr_backup" {
  count  = var.cw_to_newrelic_enabled ? 1 : 0
  bucket = aws_s3_bucket.cw_to_nr_backup[0].id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration { days = 3 }
  }
}

# ---- IAM: Firehose → S3 + HTTP endpoint ------------------------------------

resource "aws_iam_role" "cw_to_nr_firehose" {
  count = var.cw_to_newrelic_enabled ? 1 : 0
  name  = "${var.cluster_name}-cw-to-nr-firehose"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cw_to_nr_firehose_s3" {
  count = var.cw_to_newrelic_enabled ? 1 : 0
  name  = "s3-backup"
  role  = aws_iam_role.cw_to_nr_firehose[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:PutObject", "s3:GetBucketLocation"]
      Resource = [
        aws_s3_bucket.cw_to_nr_backup[0].arn,
        "${aws_s3_bucket.cw_to_nr_backup[0].arn}/*",
      ]
    }]
  })
}

# ---- IAM: CloudWatch Logs → Firehose ----------------------------------------

resource "aws_iam_role" "cw_logs_to_firehose" {
  count = var.cw_to_newrelic_enabled ? 1 : 0
  name  = "${var.cluster_name}-cw-logs-to-firehose"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cw_logs_firehose_put" {
  count = var.cw_to_newrelic_enabled ? 1 : 0
  name  = "firehose-put"
  role  = aws_iam_role.cw_logs_to_firehose[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "firehose:PutRecord"
      Resource = aws_kinesis_firehose_delivery_stream.cw_to_nr_logs[0].arn
    }]
  })
}

# ---- Kinesis Firehose → New Relic Log API -----------------------------------

resource "aws_kinesis_firehose_delivery_stream" "cw_to_nr_logs" {
  count       = var.cw_to_newrelic_enabled ? 1 : 0
  name        = "${var.cluster_name}-cw-logs-to-nr"
  destination = "http_endpoint"

  http_endpoint_configuration {
    url                = "https://log-api.newrelic.com/log/v1"
    name               = "New Relic Logs"
    access_key         = var.new_relic_license_key
    buffering_size     = 1  # MB (minimum)
    buffering_interval = 60 # seconds (minimum)
    role_arn           = aws_iam_role.cw_to_nr_firehose[0].arn
    s3_backup_mode     = "FailedDataOnly"

    s3_configuration {
      role_arn           = aws_iam_role.cw_to_nr_firehose[0].arn
      bucket_arn         = aws_s3_bucket.cw_to_nr_backup[0].arn
      buffering_size     = 5
      buffering_interval = 300
      compression_format = "GZIP"
    }
  }
}

# ---- CloudWatch Logs subscription filter ------------------------------------
# Filter pattern picks up ERROR/CRITICAL/FATAL/Exception/Traceback lines only.
# Firehose receives only matching log events — no custom code needed.

resource "aws_cloudwatch_log_subscription_filter" "cw_to_nr" {
  count           = var.cw_to_newrelic_enabled ? 1 : 0
  name            = "${var.cluster_name}-errors-to-nr"
  log_group_name  = "/aws/containerinsights/${var.cluster_name}/application"
  filter_pattern  = "?ERROR ?CRITICAL ?FATAL ?Exception ?Traceback"
  destination_arn = aws_kinesis_firehose_delivery_stream.cw_to_nr_logs[0].arn
  role_arn        = aws_iam_role.cw_logs_to_firehose[0].arn
}
