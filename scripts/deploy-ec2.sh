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

APP_SIGNALS_EC2_ROLE_ARN=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw app_signals_ec2_role_arn 2>/dev/null || echo "")

echo "==> Creating namespaces..."
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
kubectl rollout status deployment/netwatch-ui -n demo-ec2 --timeout=120s || true
kubectl rollout status deployment/device-api   -n demo-ec2 --timeout=120s || true
kubectl rollout status deployment/alert-api    -n demo-ec2 --timeout=120s || true

echo ""
echo "==> EC2 Pods:"
kubectl get pods -n demo-ec2 -o wide

echo ""
LB_HOST=$(kubectl get svc netwatch-ui -n demo-ec2 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "${LB_HOST}" ]; then
  echo "Done. NetWatch UI URL: http://${LB_HOST}"
  echo "Set EC2_BASE=http://${LB_HOST} in .env"
else
  echo "Done. LoadBalancer is provisioning. Run:"
  echo "  kubectl get svc netwatch-ui -n demo-ec2 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
fi
