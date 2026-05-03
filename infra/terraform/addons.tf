# ============================================================
# EKS Add-ons - CloudWatch Observability (Application Signals + Container Insights)
# ============================================================

# CloudWatch Observability EKS Add-on
# Installs: CloudWatch Agent, Fluent Bit, ADOT Collector, Application Signals
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_update = "OVERWRITE"

  # Associate with IRSA role for CloudWatch Agent service account
  service_account_role_arn = aws_iam_role.cloudwatch_agent.arn

  configuration_values = jsonencode({
    agent = {
      config = {
        traces = {
          traces_collected = {
            application_signals = {}
          }
        }
        logs = {
          metrics_collected = {
            application_signals = {}
            kubernetes = {
              enhanced_container_insights = true
            }
          }
        }
      }
    }
  })

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role.cloudwatch_agent,
  ]
}
