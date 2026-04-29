# ============================================================
# EKS Fargate Profile
# Covers demo-fargate namespace and kube-system (for CoreDNS on Fargate)
# ============================================================

resource "aws_iam_role" "eks_fargate" {
  name = "${var.cluster_name}-fargate-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks-fargate-pods.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_fargate_pod_execution" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.eks_fargate.name
}

resource "aws_iam_role_policy_attachment" "eks_fargate_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_fargate.name
}

resource "aws_iam_role_policy_attachment" "eks_fargate_cloudwatch" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.eks_fargate.name
}

resource "aws_iam_role_policy_attachment" "eks_fargate_xray" {
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
  role       = aws_iam_role.eks_fargate.name
}

# Fargate Profile for demo-fargate namespace
resource "aws_eks_fargate_profile" "demo_fargate" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "demo-fargate"
  pod_execution_role_arn = aws_iam_role.eks_fargate.arn
  subnet_ids             = aws_subnet.private[*].id

  selector {
    namespace = "demo-fargate"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_fargate_pod_execution,
  ]
}

# Fargate Profile for kube-system (needed if CoreDNS runs on Fargate)
# Note: We keep CoreDNS on EC2 nodes to simplify setup, this is for reference
# Uncomment if you want CoreDNS on Fargate:
# resource "aws_eks_fargate_profile" "kube_system" {
#   cluster_name           = aws_eks_cluster.main.name
#   fargate_profile_name   = "kube-system"
#   pod_execution_role_arn = aws_iam_role.eks_fargate.arn
#   subnet_ids             = aws_subnet.private[*].id
#
#   selector {
#     namespace = "kube-system"
#     labels = {
#       k8s-app = "kube-dns"
#     }
#   }
# }

# Fargate Profile for aws-observability namespace (Fluent Bit for Fargate)
resource "aws_eks_fargate_profile" "aws_observability" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "aws-observability"
  pod_execution_role_arn = aws_iam_role.eks_fargate.arn
  subnet_ids             = aws_subnet.private[*].id

  selector {
    namespace = "aws-observability"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_fargate_pod_execution,
  ]
}
