output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "EKS cluster version"
  value       = aws_eks_cluster.main.version
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "ecr_registry" {
  description = "ECR registry URL"
  value       = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repositories" {
  description = "ECR repository URLs"
  value = {
    for name, repo in aws_ecr_repository.services :
    name => repo.repository_url
  }
}

output "rum_app_monitor_id" {
  description = "CloudWatch RUM App Monitor ID"
  value       = aws_rum_app_monitor.poc.id
}

output "rum_app_monitor_arn" {
  description = "CloudWatch RUM App Monitor ARN"
  value       = aws_rum_app_monitor.poc.arn
}

output "cognito_identity_pool_id" {
  description = "Cognito Identity Pool ID for RUM"
  value       = aws_cognito_identity_pool.rum.id
}

output "newrelic_integration_role_arn" {
  description = "IAM Role ARN for New Relic AWS Integration"
  value       = aws_iam_role.newrelic_integration.arn
}

output "cloudwatch_agent_role_arn" {
  description = "IAM Role ARN for CloudWatch Agent (IRSA)"
  value       = aws_iam_role.cloudwatch_agent.arn
}

output "app_signals_ec2_role_arn" {
  description = "IAM Role ARN for Application Signals (EC2 namespace)"
  value       = aws_iam_role.app_signals_ec2.arn
}

output "app_signals_fargate_role_arn" {
  description = "IAM Role ARN for Application Signals (Fargate namespace)"
  value       = aws_iam_role.app_signals_fargate.arn
}

output "firehose_stream_name" {
  description = "Kinesis Firehose stream name for New Relic metrics"
  value       = aws_kinesis_firehose_delivery_stream.newrelic_metrics.name
}

output "synthetics_canary_name" {
  description = "CloudWatch Synthetics canary name"
  value       = aws_synthetics_canary.poc_health.name
}

output "dashboard_url" {
  description = "CloudWatch Dashboard URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${var.cluster_name}-observability-poc"
}

output "kubeconfig_command" {
  description = "Command to update kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}
