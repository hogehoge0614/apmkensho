#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CLUSTER_NAME="${CLUSTER_NAME:-obs-poc}"
NR_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:?NEW_RELIC_LICENSE_KEY must be set}"
NR_ACCOUNT_ID="${NEW_RELIC_ACCOUNT_ID:?NEW_RELIC_ACCOUNT_ID must be set}"

if [ "${NR_LICENSE_KEY}" = "your_license_key_here" ] || [ "${NR_ACCOUNT_ID}" = "your_account_id_here" ]; then
  echo "[ERROR] Set NEW_RELIC_LICENSE_KEY and NEW_RELIC_ACCOUNT_ID in .env before installing New Relic."
  exit 1
fi

echo "======================================================================"
echo " Installing New Relic Full Stack"
echo ""
echo " Instrumentation path (zero app changes):"
echo "   NR k8s-agents-operator auto-injects NR Python agent as init container"
echo "   NR Python agent -> New Relic APM (independent pipeline from CloudWatch)"
echo "======================================================================"

echo ""
echo "==> [1/6] Adding New Relic Helm repo..."
helm repo add newrelic https://helm-charts.newrelic.com
helm repo update

echo ""
echo "==> [2/6] Creating New Relic namespace and secrets..."
kubectl create namespace newrelic --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace eks-ec2-newrelic --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace eks-fargate-newrelic --dry-run=client -o yaml | kubectl apply -f -

# License key secret in the newrelic operator namespace
kubectl create secret generic newrelic-secret \
  --from-literal=license-key="${NR_LICENSE_KEY}" \
  -n newrelic \
  --dry-run=client -o yaml | kubectl apply -f -

# License key secrets in app namespaces (used by Instrumentation CRs)
for ns in eks-ec2-newrelic eks-fargate-newrelic; do
  args=(
    "--from-literal=license-key=${NR_LICENSE_KEY}"
    "--from-literal=account-id=${NR_ACCOUNT_ID}"
    "--from-literal=api-key=${NEW_RELIC_API_KEY:-}"
    "-n" "${ns}"
  )
  if [ -n "${NR_BROWSER_SNIPPET:-}" ]; then
    args+=("--from-literal=browser-snippet=${NR_BROWSER_SNIPPET}")
  fi
  kubectl create secret generic newrelic-secret "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo ""
echo "==> [3/6] Installing nri-bundle..."
echo "  Includes: infrastructure agent, kube-state-metrics, Fluent Bit,"
echo "            nri-kube-events, nri-metadata-injection, k8s-agents-operator"
helm upgrade --install nri-bundle newrelic/nri-bundle \
  --namespace newrelic \
  --create-namespace \
  -f "${ROOT_DIR}/helm-values/newrelic-values.yaml" \
  -f "${ROOT_DIR}/helm-values/newrelic-ec2-values.yaml" \
  --set global.licenseKey="${NR_LICENSE_KEY}" \
  --set global.cluster="${CLUSTER_NAME}" \
  --timeout 10m \
  --wait

echo ""
echo "==> [4/6] Applying Instrumentation CR (NR APM Auto-Attach for Python)..."
# This CR tells k8s-agents-operator which NR agent image to inject
# and how to configure it (license key, distributed tracing, etc.)
kubectl apply -f "${ROOT_DIR}/k8s/newrelic-instrumentation.yaml"
echo "  Instrumentation CRs applied to eks-ec2-newrelic and eks-fargate-newrelic namespaces"

echo ""
echo "==> [5/6] New Relic AWS Integration setup..."
NR_INTEGRATION_ROLE=$(cd "${ROOT_DIR}/infra/terraform" && \
  terraform output -raw newrelic_integration_role_arn 2>/dev/null || echo "")
if [ -n "${NR_INTEGRATION_ROLE}" ]; then
  echo "  New Relic Integration Role ARN: ${NR_INTEGRATION_ROLE}"
fi
echo "  To enable CloudWatch metrics polling in NR:"
echo "    NR UI > Infrastructure > AWS > Add AWS Account"
echo "    Role ARN: ${NR_INTEGRATION_ROLE:-<see terraform output newrelic_integration_role_arn>}"
echo "    External ID: ${NR_ACCOUNT_ID}"

echo ""
echo "==> [6/6] Verifying New Relic pods..."
kubectl get pods -n newrelic

echo ""
echo "======================================================================"
echo " New Relic Full Stack Ready"
echo "======================================================================"
echo ""
echo " Architecture (zero app changes):"
echo "   App pods (plain FastAPI image — same image as CloudWatch path)"
echo "   → k8s-agents-operator (NR, analogous to OTel Operator)"
echo "     injects NR Python agent as init container"
echo "   → NR Python agent auto-instruments FastAPI, propagates distributed traces"
echo "   → New Relic APM + Distributed Tracing + Service Maps"
echo "   nri-bundle DaemonSet → New Relic Kubernetes / Infrastructure"
echo "   Fluent Bit → New Relic Logs"
echo ""
echo " Next steps:"
echo "   make ec2-newrelic-deploy             # Deploy apps to eks-ec2-newrelic namespace"
echo "   make fargate-newrelic-deploy         # Deploy apps to eks-fargate-newrelic namespace"
echo "   make port-forward-newrelic           # http://localhost:8082"
echo "   make port-forward-fargate-newrelic   # http://localhost:8083"
echo "   make load                            # Generate traces"
echo ""
echo " New Relic Console:"
echo "   APM:     https://one.newrelic.com/apm"
echo "   K8s:     https://one.newrelic.com/kubernetes"
echo "   Tracing: https://one.newrelic.com/distributed-tracing"
