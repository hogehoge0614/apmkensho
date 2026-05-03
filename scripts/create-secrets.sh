#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

APP_NAMESPACES=(
  "eks-ec2-appsignals"
  "eks-fargate-appsignals"
  "eks-ec2-newrelic"
  "eks-fargate-newrelic"
)
NEW_RELIC_NAMESPACES=(
  "newrelic"
  "eks-ec2-newrelic"
  "eks-fargate-newrelic"
)

echo "==> Creating application namespaces..."
for ns in "${APP_NAMESPACES[@]}" newrelic; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done

echo ""
echo "==> Creating database secrets (device-api-db)..."
RDS_ENDPOINT=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw rds_endpoint 2>/dev/null || echo "")
RDS_PASSWORD=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw rds_password 2>/dev/null || echo "")

if [ -z "${RDS_ENDPOINT}" ] || [ -z "${RDS_PASSWORD}" ]; then
  echo "  [WARN] RDS outputs not found. Run 'make up' first, then re-run this target."
else
  DB_URL="postgresql://netwatch:${RDS_PASSWORD}@${RDS_ENDPOINT}/netwatch"
  for ns in "${APP_NAMESPACES[@]}"; do
    kubectl create secret generic device-api-db \
      --from-literal=DATABASE_URL="${DB_URL}" \
      -n "${ns}" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "  Created/updated device-api-db in namespace: ${ns}"
  done
fi

echo ""
echo "==> Creating New Relic secrets when configured..."
if [ -z "${NEW_RELIC_LICENSE_KEY:-}" ] || [ "${NEW_RELIC_LICENSE_KEY}" = "your_license_key_here" ]; then
  echo "  [SKIP] NEW_RELIC_LICENSE_KEY is not configured."
else
  for ns in "${NEW_RELIC_NAMESPACES[@]}"; do
    kubectl create secret generic newrelic-secret \
      --from-literal=license-key="${NEW_RELIC_LICENSE_KEY}" \
      --from-literal=api-key="${NEW_RELIC_API_KEY:-}" \
      --from-literal=account-id="${NEW_RELIC_ACCOUNT_ID:-}" \
      -n "${ns}" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "  Created/updated newrelic-secret in namespace: ${ns}"
  done

  if [ -n "${NR_BROWSER_SNIPPET:-}" ]; then
    for ns in eks-ec2-newrelic eks-fargate-newrelic; do
      kubectl create secret generic newrelic-secret \
        --from-literal=license-key="${NEW_RELIC_LICENSE_KEY}" \
        --from-literal=api-key="${NEW_RELIC_API_KEY:-}" \
        --from-literal=account-id="${NEW_RELIC_ACCOUNT_ID:-}" \
        --from-literal=browser-snippet="${NR_BROWSER_SNIPPET}" \
        -n "${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -
      echo "  Added browser-snippet to newrelic-secret in namespace: ${ns}"
    done
  fi
fi

echo ""
echo "==> Verifying secrets..."
for ns in "${APP_NAMESPACES[@]}"; do
  printf "  %-26s device-api-db: " "${ns}"
  kubectl get secret device-api-db -n "${ns}" -o name 2>/dev/null || true
done
for ns in "${NEW_RELIC_NAMESPACES[@]}"; do
  printf "  %-26s newrelic-secret: " "${ns}"
  kubectl get secret newrelic-secret -n "${ns}" -o name 2>/dev/null || true
done

echo ""
echo "Done."
