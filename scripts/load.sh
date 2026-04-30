#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EC2_BASE="${EC2_BASE:-http://localhost:8080}"
FARGATE_BASE="${FARGATE_BASE:-http://localhost:8081}"
NEWRELIC_BASE="${NEWRELIC_BASE:-}"
ROUNDS="${ROUNDS:-3}"
DELAY="${DELAY:-1}"

SCENARIOS=(
  "devices"
  "devices?area=tokyo"
  "devices?area=osaka"
  "devices?area=nagoya"
  "devices?area=fukuoka"
  "devices?type=core_router"
  "devices?status=warning"
  "devices?status=critical"
  "devices/TKY-CORE-001"
  "devices/OSK-L3SW-001"
  "devices/FUK-EDGE-001"
  "devices/TKY-AP-002"
  "alerts"
  "alerts?severity=critical"
  "alerts?severity=warning"
  "devices?q=OSK"
)

run_requests() {
  local base="$1"
  local label="$2"

  echo ""
  echo "=== Running load against ${label} (${base}) ==="

  for scenario in "${SCENARIOS[@]}"; do
    local url="${base}/${scenario}"
    local req_id="load-$(python3 -c "import time; print(int(time.time()*1000))")-${RANDOM}"
    local start=$(python3 -c "import time; print(int(time.time()*1000))")

    echo -n "  ${scenario}: "
    response=$(curl -sf -w "\n%{http_code}" \
      -H "X-Request-Id: ${req_id}" \
      -H "X-Load-Test: true" \
      "${url}" 2>/dev/null || echo "ERROR")

    local http_code=$(echo "${response}" | tail -1)
    local end=$(python3 -c "import time; print(int(time.time()*1000))")
    local latency=$((end - start))

    if echo "${response}" | grep -q "ERROR"; then
      echo "FAILED (connection error) ${latency}ms"
    elif [ "${http_code}" = "500" ]; then
      echo "HTTP 500 (server error) ${latency}ms"
    else
      echo "HTTP ${http_code} ${latency}ms"
    fi
    sleep "${DELAY}"
  done
}

echo "======================================================"
echo " NetWatch Load Generator"
echo " Rounds: ${ROUNDS}, Delay: ${DELAY}s between requests"
echo "======================================================"

for round in $(seq 1 "${ROUNDS}"); do
  echo ""
  echo "====== Round ${round}/${ROUNDS} ======"

  if curl -sf "${EC2_BASE}/health" > /dev/null 2>&1; then
    run_requests "${EC2_BASE}" "EC2"
  else
    echo "  [SKIP] EC2 frontend not reachable at ${EC2_BASE}"
    echo "  Set EC2_BASE in .env"
  fi

  if curl -sf "${FARGATE_BASE}/health" > /dev/null 2>&1; then
    run_requests "${FARGATE_BASE}" "Fargate"
  else
    echo "  [SKIP] Fargate frontend not reachable at ${FARGATE_BASE}"
  fi

  if [ -n "${NEWRELIC_BASE}" ] && curl -sf "${NEWRELIC_BASE}/health" > /dev/null 2>&1; then
    run_requests "${NEWRELIC_BASE}" "NewRelic"
  elif [ -z "${NEWRELIC_BASE}" ]; then
    echo "  [SKIP] NEWRELIC_BASE not set in .env"
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
echo "======================================================"
