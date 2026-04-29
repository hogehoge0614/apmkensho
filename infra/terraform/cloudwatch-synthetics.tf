# ============================================================
# CloudWatch Synthetics - Canary for external monitoring
# ============================================================

# S3 bucket for Synthetics artifacts
resource "aws_s3_bucket" "synthetics" {
  bucket        = "${var.cluster_name}-synthetics-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "synthetics" {
  bucket = aws_s3_bucket.synthetics.id

  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = 3
    }
  }
}

# Zip the canary script using archive_file data source
data "archive_file" "canary_zip" {
  type        = "zip"
  output_path = "${path.module}/canary/poc-canary.zip"

  source {
    content  = file("${path.module}/canary/poc-canary.py")
    filename = "python/poc-canary.py"
  }
}

# Upload canary zip to S3
resource "aws_s3_object" "canary_script" {
  bucket = aws_s3_bucket.synthetics.id
  key    = "canary/poc-canary.zip"
  source = data.archive_file.canary_zip.output_path
  etag   = data.archive_file.canary_zip.output_md5

  depends_on = [data.archive_file.canary_zip]
}

# CloudWatch Synthetics Canary
resource "aws_synthetics_canary" "poc_health" {
  name                 = "${var.cluster_name}-health-check"
  artifact_s3_location = "s3://${aws_s3_bucket.synthetics.id}/canary-results/"
  execution_role_arn   = aws_iam_role.synthetics.arn
  handler              = "poc-canary.handler"
  s3_bucket            = aws_s3_bucket.synthetics.id
  s3_key               = aws_s3_object.canary_script.key
  runtime_version      = "syn-python-selenium-10.0"
  start_canary         = false  # Start manually during PoC to avoid charges

  schedule {
    expression = "rate(5 minutes)"
  }

  run_config {
    timeout_in_seconds = 30
    environment_variables = {
      TARGET_URL = var.synthetics_canary_url
    }
  }

  depends_on = [aws_s3_object.canary_script]
}
