#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
ECR_REGISTRY="${ECR_REGISTRY:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com}"
CLUSTER_NAME="${CLUSTER_NAME:-obs-poc}"

# Get IRSA role ARNs from Terraform output
APP_SIGNALS_EC2_ROLE_ARN=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw app_signals_ec2_role_arn 2>/dev/null || echo "")

echo "==> Creating namespaces..."
# Apply namespace with role ARN substitution
sed \
  -e "s|\${APP_SIGNALS_EC2_ROLE_ARN}|${APP_SIGNALS_EC2_ROLE_ARN}|g" \
  -e "s|\${APP_SIGNALS_FARGATE_ROLE_ARN}|${APP_SIGNALS_EC2_ROLE_ARN}|g" \
  "${ROOT_DIR}/k8s/namespaces.yaml" | kubectl apply -f -

echo "==> Deploying EC2 manifests to demo-ec2 namespace..."
for manifest in "${ROOT_DIR}/k8s/ec2/"*.yaml; do
  echo "  Applying: $(basename ${manifest})"
  sed "s|\${ECR_REGISTRY}|${ECR_REGISTRY}|g" "${manifest}" | kubectl apply -f -
done

echo ""
echo "==> Waiting for pods to be ready..."
kubectl rollout status deployment/frontend-ui -n demo-ec2 --timeout=120s || true
kubectl rollout status deployment/backend-for-frontend -n demo-ec2 --timeout=120s || true
kubectl rollout status deployment/order-api -n demo-ec2 --timeout=120s || true
kubectl rollout status deployment/inventory-api -n demo-ec2 --timeout=120s || true
kubectl rollout status deployment/payment-api -n demo-ec2 --timeout=120s || true
kubectl rollout status deployment/external-api-simulator -n demo-ec2 --timeout=120s || true

echo ""
echo "==> EC2 Pods:"
kubectl get pods -n demo-ec2 -o wide

echo ""
echo "Done. Use 'make port-forward-ec2' to access the UI."
