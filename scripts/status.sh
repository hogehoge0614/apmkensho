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
echo "=== demo-ec2 Pods ==="
kubectl get pods -n demo-ec2 -o wide 2>/dev/null || echo "Namespace not found"

echo ""
echo "=== demo-fargate Pods ==="
kubectl get pods -n demo-fargate -o wide 2>/dev/null || echo "Namespace not found"

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
echo "=== Services ==="
echo "--- demo-ec2 ---"
kubectl get svc -n demo-ec2 2>/dev/null || true
echo "--- demo-fargate ---"
kubectl get svc -n demo-fargate 2>/dev/null || true

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
