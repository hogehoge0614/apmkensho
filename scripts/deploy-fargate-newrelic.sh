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
NS="eks-fargate-newrelic"
APP_SIGNALS_EC2_ROLE_ARN=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw app_signals_ec2_role_arn 2>/dev/null || echo "")
APP_SIGNALS_FARGATE_ROLE_ARN=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw app_signals_fargate_role_arn 2>/dev/null || echo "")

if ! kubectl get crd instrumentations.newrelic.com >/dev/null 2>&1; then
  echo "[ERROR] New Relic Instrumentation CRD is not installed."
  echo "Run 'make install-newrelic-full' first, then re-run 'make fargate-newrelic-deploy'."
  exit 1
fi

echo "============================================================"
echo " EKS on Fargate + New Relic (APM traces only)"
echo " NOTE: Infrastructure Agent (DaemonSet) is not supported on Fargate."
echo "       Infra metrics and NR Logs Fluent Bit will not be collected."
echo "============================================================"
echo ""

echo "==> Creating namespaces and ServiceAccounts..."
sed \
  -e "s|\${APP_SIGNALS_EC2_ROLE_ARN}|${APP_SIGNALS_EC2_ROLE_ARN}|g" \
  -e "s|\${APP_SIGNALS_FARGATE_ROLE_ARN}|${APP_SIGNALS_FARGATE_ROLE_ARN}|g" \
  "${ROOT_DIR}/k8s/namespaces.yaml" | kubectl apply -f -

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
echo "==> Creating New Relic license key secret in ${NS} namespace..."
if [ -z "${NEW_RELIC_LICENSE_KEY:-}" ] || [ "${NEW_RELIC_LICENSE_KEY:-}" = "your_license_key_here" ]; then
  echo "  [WARN] NEW_RELIC_LICENSE_KEY not set in .env — NR agent injection will not report data"
else
  args=(
    "--namespace" "${NS}"
    "--from-literal=license-key=${NEW_RELIC_LICENSE_KEY}"
    "--from-literal=account-id=${NEW_RELIC_ACCOUNT_ID:-}"
    "--from-literal=api-key=${NEW_RELIC_API_KEY:-}"
  )
  if [ -n "${NR_BROWSER_SNIPPET:-}" ]; then
    args+=("--from-literal=browser-snippet=${NR_BROWSER_SNIPPET}")
  fi
  kubectl create secret generic newrelic-secret "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  Secret newrelic-secret created/updated."
fi

echo ""
echo "==> Applying New Relic Instrumentation CRs..."
kubectl apply -f "${ROOT_DIR}/k8s/newrelic-instrumentation.yaml"

echo ""
echo "==> Deploying manifests to ${NS} namespace..."
for manifest in "${ROOT_DIR}/k8s/eks-fargate-newrelic/"*.yaml; do
  echo "  Applying: $(basename ${manifest})"
  sed "s|\${ECR_REGISTRY}|${ECR_REGISTRY}|g" "${manifest}" | kubectl apply -f -
done

echo ""
echo "==> Waiting for Fargate pods (may take 1-2 min for node provisioning)..."
kubectl rollout status deployment/metrics-collector -n "${NS}" --timeout=180s || true
kubectl rollout status deployment/device-api        -n "${NS}" --timeout=180s || true
kubectl rollout status deployment/alert-api         -n "${NS}" --timeout=180s || true
kubectl rollout status deployment/netwatch-ui       -n "${NS}" --timeout=180s || true

echo ""
echo "==> Pods (${NS}):"
kubectl get pods -n "${NS}" -o wide

echo ""
LB_HOST=$(kubectl get svc netwatch-ui -n "${NS}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "${LB_HOST}" ]; then
  echo "Done. NetWatch UI: http://${LB_HOST}"
  echo "Set FARGATE_NR_BASE=http://${LB_HOST} in .env"
else
  echo "Done. LoadBalancer is provisioning. Run:"
  echo "  kubectl get svc netwatch-ui -n ${NS} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
fi
