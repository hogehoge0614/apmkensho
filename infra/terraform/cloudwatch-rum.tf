# ============================================================
# CloudWatch RUM (Real User Monitoring)
# ============================================================

resource "aws_rum_app_monitor" "poc" {
  name   = "${var.cluster_name}-rum"
  domain = "localhost"

  app_monitor_configuration {
    allow_cookies       = true
    enable_xray         = true
    session_sample_rate = 1.0
    telemetries         = ["errors", "performance", "http"]
  }

  custom_events {
    status = "ENABLED"
  }
}

# Cognito Identity Pool for RUM (unauthenticated access for client-side data)
resource "aws_cognito_identity_pool" "rum" {
  identity_pool_name               = "${var.cluster_name}-rum-pool"
  allow_unauthenticated_identities = true
}

resource "aws_iam_role" "rum_cognito" {
  name = "${var.cluster_name}-rum-cognito"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "cognito-identity.amazonaws.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.rum.id
          }
          "ForAnyValue:StringLike" = {
            "cognito-identity.amazonaws.com:amr" = "unauthenticated"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "rum_put" {
  name = "rum-put"
  role = aws_iam_role.rum_cognito.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rum:PutRumEvents"
        ]
        Resource = aws_rum_app_monitor.poc.arn
      }
    ]
  })
}

resource "aws_cognito_identity_pool_roles_attachment" "rum" {
  identity_pool_id = aws_cognito_identity_pool.rum.id

  roles = {
    "unauthenticated" = aws_iam_role.rum_cognito.arn
  }
}
