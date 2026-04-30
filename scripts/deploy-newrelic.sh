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

echo "==> Creating namespace and ServiceAccount for New Relic path..."
kubectl apply -f "${ROOT_DIR}/k8s/namespaces.yaml"

echo "==> Deploying New Relic path manifests to demo-newrelic namespace..."
for manifest in "${ROOT_DIR}/k8s/newrelic/"*.yaml; do
  echo "  Applying: $(basename ${manifest})"
  sed "s|\${ECR_REGISTRY}|${ECR_REGISTRY}|g" "${manifest}" | kubectl apply -f -
done

echo ""
echo "==> Waiting for pods to be ready..."
echo "  Note: init container injection by k8s-agents-operator adds ~30s to startup"
kubectl rollout status deployment/frontend-ui -n demo-newrelic --timeout=180s || true
kubectl rollout status deployment/backend-for-frontend -n demo-newrelic --timeout=180s || true
kubectl rollout status deployment/order-api -n demo-newrelic --timeout=180s || true
kubectl rollout status deployment/inventory-api -n demo-newrelic --timeout=180s || true
kubectl rollout status deployment/payment-api -n demo-newrelic --timeout=180s || true
kubectl rollout status deployment/external-api-simulator -n demo-newrelic --timeout=180s || true

echo ""
echo "==> New Relic path pods:"
kubectl get pods -n demo-newrelic -o wide

echo ""
echo "==> Verify NR agent injection (should show newrelic-init init container):"
kubectl get pod -n demo-newrelic -l app=frontend-ui -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null || true
echo ""

echo ""
LB_HOST=$(kubectl get svc frontend-ui -n demo-newrelic -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "${LB_HOST}" ]; then
  echo "Done. New Relic frontend URL: http://${LB_HOST}"
  echo "Set NEWRELIC_BASE=http://${LB_HOST} in .env"
else
  echo "Done. LoadBalancer is provisioning. Run the following to get the URL:"
  echo "  kubectl get svc frontend-ui -n demo-newrelic -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
fi
