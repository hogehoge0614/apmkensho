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
NS="eks-ec2-newrelic"

echo "==> Creating namespaces and ServiceAccounts..."
kubectl apply -f "${ROOT_DIR}/k8s/namespaces.yaml"

echo "==> Creating database secret (device-api-db) for ${NS}..."
RDS_ENDPOINT=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw rds_endpoint 2>/dev/null || echo "")
RDS_PASSWORD=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw rds_password 2>/dev/null || echo "")

if [ -n "${RDS_ENDPOINT}" ]; then
  DB_URL="postgresql://netwatch:${RDS_PASSWORD}@${RDS_ENDPOINT}/netwatch"
  kubectl create secret generic device-api-db \
    --namespace "${NS}" \
    --from-literal=DATABASE_URL="${DB_URL}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  Secret device-api-db created/updated."
else
  echo "  [WARN] rds_endpoint not found — device-api will fail to start."
fi

echo ""
echo "==> Applying New Relic Instrumentation CRs..."
kubectl apply -f "${ROOT_DIR}/k8s/newrelic-instrumentation.yaml"

echo ""
echo "==> Deploying manifests to ${NS} namespace..."
for manifest in "${ROOT_DIR}/k8s/eks-ec2-newrelic/"*.yaml; do
  echo "  Applying: $(basename ${manifest})"
  sed "s|\${ECR_REGISTRY}|${ECR_REGISTRY}|g" "${manifest}" | kubectl apply -f -
done

echo ""
echo "==> Waiting for pods to be ready..."
echo "  Note: k8s-agents-operator init container injection adds ~30s to startup"
kubectl rollout status deployment/metrics-collector -n "${NS}" --timeout=180s || true
kubectl rollout status deployment/device-api        -n "${NS}" --timeout=180s || true
kubectl rollout status deployment/alert-api         -n "${NS}" --timeout=180s || true
kubectl rollout status deployment/netwatch-ui       -n "${NS}" --timeout=180s || true

echo ""
echo "==> Pods (${NS}):"
kubectl get pods -n "${NS}" -o wide

echo ""
echo "==> Verify NR agent injection (should show newrelic-init init container):"
kubectl get pod -n "${NS}" -l app=netwatch-ui \
  -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null && echo "" || true

echo ""
LB_HOST=$(kubectl get svc netwatch-ui -n "${NS}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "${LB_HOST}" ]; then
  echo "Done. NetWatch UI: http://${LB_HOST}"
  echo "Set EC2_NR_BASE=http://${LB_HOST} in .env"
else
  echo "Done. LoadBalancer is provisioning. Run:"
  echo "  kubectl get svc netwatch-ui -n ${NS} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
fi
