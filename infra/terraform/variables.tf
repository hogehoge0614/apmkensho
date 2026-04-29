variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "obs-poc"
}

variable "cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.30"
}

variable "node_instance_type" {
  description = "EC2 instance type for managed node group"
  type        = string
  default     = "t3.medium"
}

variable "node_count" {
  description = "Number of EC2 nodes in managed node group"
  type        = number
  default     = 1
}

variable "new_relic_account_id" {
  description = "New Relic account ID"
  type        = string
  default     = ""
  sensitive   = true
}

variable "new_relic_license_key" {
  description = "New Relic license key"
  type        = string
  default     = ""
  sensitive   = true
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "services" {
  description = "List of microservices for ECR repositories"
  type        = list(string)
  default = [
    "frontend-ui",
    "backend-for-frontend",
    "order-api",
    "inventory-api",
    "payment-api",
    "external-api-simulator"
  ]
}

variable "synthetics_canary_url" {
  description = "URL for CloudWatch Synthetics canary to monitor (set after getting endpoint)"
  type        = string
  default     = "https://example.com"
}

variable "new_relic_metric_stream_enabled" {
  description = "Enable CloudWatch Metric Streams to New Relic"
  type        = bool
  default     = true
}
