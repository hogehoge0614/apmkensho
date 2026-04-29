#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

NR_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:?NEW_RELIC_LICENSE_KEY must be set in .env}"
NR_API_KEY="${NEW_RELIC_API_KEY:-}"
NR_ACCOUNT_ID="${NEW_RELIC_ACCOUNT_ID:-}"

echo "==> Creating New Relic secrets in all namespaces..."
# demo-ec2 / demo-fargate: CloudWatch path (secrets unused by OTel agent but kept for consistency)
# demo-newrelic: NR APM Auto-Attach reads license-key via Instrumentation CR
# newrelic: nri-bundle Helm release reads global.licenseKey
for ns in demo-ec2 demo-fargate demo-newrelic newrelic; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic newrelic-secret \
    --from-literal=license-key="${NR_LICENSE_KEY}" \
    --from-literal=api-key="${NR_API_KEY}" \
    --from-literal=account-id="${NR_ACCOUNT_ID}" \
    -n "${ns}" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "  Created newrelic-secret in namespace: ${ns}"
done

echo ""
echo "==> Verifying secrets..."
for ns in demo-ec2 demo-fargate demo-newrelic newrelic; do
  echo "  ${ns}:"
  kubectl get secret newrelic-secret -n "${ns}" -o jsonpath='{.metadata.name}' 2>/dev/null && echo " ✓" || echo " ✗"
done

echo ""
echo "Done. Secrets created for demo-ec2, demo-fargate, demo-newrelic, newrelic namespaces."
