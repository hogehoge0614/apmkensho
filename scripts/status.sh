#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CLUSTER_NAME="${CLUSTER_NAME:-obs-poc}"

echo "======================================================"
echo " Observability PoC Status Check"
echo "======================================================"

echo ""
echo "=== EKS Nodes ==="
kubectl get nodes -o wide 2>/dev/null || echo "Cannot connect to cluster"

echo ""
echo "=== [1/4] EKS on EC2 + App Signals (eks-ec2-appsignals) ==="
kubectl get pods -n eks-ec2-appsignals -o wide 2>/dev/null || echo "Namespace not found"

echo ""
echo "=== [2/4] EKS on Fargate + App Signals (eks-fargate-appsignals) ==="
kubectl get pods -n eks-fargate-appsignals -o wide 2>/dev/null || echo "Namespace not found"

echo ""
echo "=== [3/4] EKS on EC2 + New Relic (eks-ec2-newrelic) ==="
kubectl get pods -n eks-ec2-newrelic -o wide 2>/dev/null || echo "Namespace not found"

echo ""
echo "=== [4/4] EKS on Fargate + New Relic (eks-fargate-newrelic) ==="
kubectl get pods -n eks-fargate-newrelic -o wide 2>/dev/null || echo "Namespace not found"

echo ""
echo "=== CloudWatch Agent Pods (amazon-cloudwatch) ==="
kubectl get pods -n amazon-cloudwatch -o wide 2>/dev/null || echo "Namespace not found"

echo ""
echo "=== New Relic Pods (newrelic) ==="
kubectl get pods -n newrelic -o wide 2>/dev/null || echo "Namespace not found"

echo ""
echo "=== EKS Add-ons ==="
aws eks list-addons \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --output table 2>/dev/null || echo "Cannot list add-ons"

echo ""
echo "=== Helm Releases ==="
helm list -A 2>/dev/null || echo "Cannot list Helm releases"

echo ""
echo "=== Services (LoadBalancer URLs) ==="
for ns in eks-ec2-appsignals eks-fargate-appsignals eks-ec2-newrelic eks-fargate-newrelic; do
  echo "--- ${ns} ---"
  kubectl get svc -n "${ns}" 2>/dev/null || true
done

echo ""
echo "=== CloudWatch Metric Streams ==="
aws cloudwatch list-metric-streams \
  --region "${AWS_REGION}" \
  --query "Entries[].{Name:Name,State:State}" \
  --output table 2>/dev/null || echo "Cannot list metric streams"

echo ""
echo "=== CloudWatch Synthetics Canaries ==="
aws synthetics describe-canaries \
  --region "${AWS_REGION}" \
  --query "Canaries[].{Name:Name,Status:Status.State}" \
  --output table 2>/dev/null || echo "Cannot list canaries"
