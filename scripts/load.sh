#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Target: frontend-ui LoadBalancer URL (set EC2_BASE / FARGATE_BASE / NEWRELIC_BASE in .env)
EC2_BASE="${EC2_BASE:-http://localhost:8080}"
FARGATE_BASE="${FARGATE_BASE:-http://localhost:8081}"
NEWRELIC_BASE="${NEWRELIC_BASE:-}"
ROUNDS="${ROUNDS:-3}"
DELAY="${DELAY:-2}"

SCENARIOS=(
  "checkout/normal"
  "checkout/slow-inventory"
  "checkout/slow-payment"
  "checkout/payment-error"
  "checkout/external-slow"
  "checkout/random"
  "search?q=shoes"
  "user-journey"
)

run_requests() {
  local base="$1"
  local label="$2"

  echo ""
  echo "=== Running load against ${label} (${base}) ==="

  for scenario in "${SCENARIOS[@]}"; do
    local url="${base}/api/${scenario}"
    local req_id="load-$(date +%s%N | head -c 16)"
    local start=$(date +%s%3N)

    echo -n "  ${scenario}: "
    response=$(curl -sf -w "\n%{http_code}" \
      -H "X-Request-Id: ${req_id}" \
      -H "X-Load-Test: true" \
      "${url}" 2>/dev/null || echo "ERROR")

    local http_code=$(echo "${response}" | tail -1)
    local end=$(date +%s%3N)
    local latency=$((end - start))

    if echo "${response}" | grep -q "ERROR"; then
      echo "FAILED (connection error) ${latency}ms"
    elif [ "${http_code}" = "500" ]; then
      echo "HTTP 500 (expected for error scenarios) ${latency}ms"
    else
      echo "HTTP ${http_code} ${latency}ms"
    fi
    sleep "${DELAY}"
  done
}

echo "======================================================"
echo " Observability PoC Load Generator"
echo " Rounds: ${ROUNDS}, Delay: ${DELAY}s between requests"
echo "======================================================"

for round in $(seq 1 "${ROUNDS}"); do
  echo ""
  echo "====== Round ${round}/${ROUNDS} ======"

  # Check if EC2 frontend is reachable
  if curl -sf "${EC2_BASE}/health" > /dev/null 2>&1; then
    run_requests "${EC2_BASE}" "EC2"
  else
    echo "  [SKIP] EC2 frontend not reachable at ${EC2_BASE}"
    echo "  Run 'make port-forward-ec2' in another terminal first"
  fi

  # Check if Fargate frontend is reachable
  if curl -sf "${FARGATE_BASE}/health" > /dev/null 2>&1; then
    run_requests "${FARGATE_BASE}" "Fargate"
  else
    echo "  [SKIP] Fargate frontend not reachable at ${FARGATE_BASE}"
    echo "  Set FARGATE_BASE in .env to the LoadBalancer hostname"
  fi

  # Check if New Relic frontend is reachable
  if [ -n "${NEWRELIC_BASE}" ] && curl -sf "${NEWRELIC_BASE}/health" > /dev/null 2>&1; then
    run_requests "${NEWRELIC_BASE}" "NewRelic"
  elif [ -z "${NEWRELIC_BASE}" ]; then
    echo "  [SKIP] NEWRELIC_BASE not set in .env"
  else
    echo "  [SKIP] New Relic frontend not reachable at ${NEWRELIC_BASE}"
  fi

  if [ "${round}" -lt "${ROUNDS}" ]; then
    echo ""
    echo "  Waiting ${DELAY}s before next round..."
    sleep "${DELAY}"
  fi
done

echo ""
echo "======================================================"
echo " Load generation complete!"
echo " Check traces in:"
echo "   CloudWatch Application Signals:"
echo "   https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services"
echo "   New Relic APM:"
echo "   https://one.newrelic.com/apm"
echo "======================================================"
