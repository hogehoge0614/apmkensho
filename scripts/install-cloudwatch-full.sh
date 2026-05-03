#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CLUSTER_NAME="${CLUSTER_NAME:-obs-poc}"

echo "======================================================================"
echo " Installing CloudWatch + Application Signals Full Stack"
echo ""
echo " Instrumentation path (zero app changes):"
echo "   OTel Operator (CW addon) auto-injects OTel SDK as init container"
echo "   OTel SDK -> OTLP -> CloudWatch Agent (ADOT) -> Application Signals"
echo "======================================================================"

echo ""
echo "==> [1/5] Verifying CloudWatch Observability EKS Add-on..."
aws eks describe-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name amazon-cloudwatch-observability \
  --region "${AWS_REGION}" \
  --query 'addon.{status:status,version:addonVersion}' \
  --output table || echo "  Add-on not found - check Terraform apply"

echo ""
echo "==> [2/5] Enabling Application Signals for the cluster..."
aws cloudwatch enable-application-signals \
  --region "${AWS_REGION}" 2>/dev/null || echo "  Application Signals already enabled"

echo ""
echo "==> [3/5] Annotating namespaces for OTel Python auto-instrumentation..."
# The CloudWatch Observability addon's OTel Operator reads this annotation
# and injects the Python SDK as an init container — no app code change needed
for ns in eks-ec2-appsignals eks-fargate-appsignals; do
  kubectl annotate namespace "${ns}" \
    "instrumentation.opentelemetry.io/inject-python=true" \
    --overwrite 2>/dev/null || true
  echo "  Annotated namespace: ${ns}"
done

echo ""
echo "==> [4/5] Verifying CloudWatch Agent pods..."
kubectl get pods -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent 2>/dev/null || \
  echo "  CloudWatch agent pods not found"

echo ""
echo "==> [5/5] Verifying Fluent Bit DaemonSet (EC2 log collection)..."
kubectl get daemonset -n amazon-cloudwatch -l app.kubernetes.io/name=fluent-bit 2>/dev/null || \
  echo "  Fluent Bit DaemonSet not found"

echo ""
echo "======================================================================"
echo " CloudWatch Full Stack Ready"
echo "======================================================================"
echo ""
echo " Architecture (zero app changes):"
echo "   App pods (plain FastAPI image — no instrumentation code)"
echo "   → OTel Operator (from amazon-cloudwatch-observability addon)"
echo "     injects OTel Python SDK as init container"
echo "   → OTel SDK auto-instruments FastAPI, propagates W3C trace context"
echo "   → EC2: OTLP → cloudwatch-agent.amazon-cloudwatch:4316"
echo "   → Fargate: OTLP → namespace-local adot-collector:4316"
echo "   → CloudWatch Application Signals (APM + Service Map + SLOs)"
echo "   → X-Ray (distributed tracing)"
echo ""
echo " Next steps:"
echo "   make ec2-appsignals-deploy      # Deploy apps to eks-ec2-appsignals"
echo "   make fargate-appsignals-deploy  # Deploy apps to eks-fargate-appsignals"
echo "   make port-forward-ec2       # http://localhost:8080"
echo "   make load                   # Generate traces"
echo ""
echo " CloudWatch Console:"
echo "   https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#application-signals:services"
