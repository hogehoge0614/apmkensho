#!/usr/bin/env bash
# Usage:
#   ./scripts/load.sh                    # デフォルト: all scenarios, ROUNDS回繰り返し
#   ./scripts/load.sh normal-dashboard   # ダッシュボードのみ
#   ./scripts/load.sh normal-devices     # 機器一覧
#   ./scripts/load.sh normal-device-detail  # 機器詳細（3ホップトレース）
#   ./scripts/load.sh normal-alerts      # アラート一覧
#   ./scripts/load.sh slow-query-devices # Slow Query ON後の機器一覧連打
#   ./scripts/load.sh error-inject-devices # Error Inject後の機器一覧連打
#   ./scripts/load.sh alert-storm-alerts # Alert Storm後のアラート一覧
#   ./scripts/load.sh mixed-user-flow    # ユーザー回遊シナリオ
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EC2_AS_BASE="${EC2_AS_BASE-http://localhost:8080}"
FARGATE_AS_BASE="${FARGATE_AS_BASE-http://localhost:8081}"
EC2_NR_BASE="${EC2_NR_BASE-}"
FARGATE_NR_BASE="${FARGATE_NR_BASE-}"
ROUNDS="${ROUNDS:-3}"
DELAY="${DELAY:-1}"
SCENARIO="${1:-all}"

# ── 全シナリオリスト（デフォルト） ────────────────────────────────────────
ALL_SCENARIOS=(
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

# ── シナリオ別リスト ──────────────────────────────────────────────────────
NORMAL_DASHBOARD_SCENARIOS=("")
NORMAL_DEVICES_SCENARIOS=(
  "devices"
  "devices?area=tokyo"
  "devices?area=osaka"
  "devices?area=nagoya"
  "devices?area=fukuoka"
  "devices?status=warning"
  "devices?status=critical"
)
NORMAL_DEVICE_DETAIL_SCENARIOS=(
  "devices/TKY-CORE-001"
  "devices/OSK-L3SW-001"
  "devices/OSK-CORE-001"
  "devices/FUK-CORE-001"
  "devices/SPR-CORE-001"
  "devices/NGY-CORE-001"
  "devices/TKY-L3SW-001"
)
NORMAL_ALERTS_SCENARIOS=(
  "alerts"
  "alerts?severity=critical"
  "alerts?severity=warning"
)
SLOW_QUERY_DEVICES_SCENARIOS=(
  "devices"
  "devices?area=tokyo"
  "devices/TKY-CORE-001"
  "devices/OSK-L3SW-001"
  "devices"
  "devices/TKY-EDGE-001"
)
ERROR_INJECT_DEVICES_SCENARIOS=(
  "devices"
  "devices?area=tokyo"
  "devices?area=osaka"
  "devices?status=active"
  "devices"
  "devices?type=core_router"
  "devices"
  "devices?area=nagoya"
)
ALERT_STORM_ALERTS_SCENARIOS=(
  "alerts"
  "alerts?severity=critical"
  "alerts?severity=warning"
  "alerts"
)
MIXED_USER_FLOW_SCENARIOS=(
  ""
  "devices"
  "devices/TKY-CORE-001"
  "alerts"
  "chaos"
)

# ── 単一リクエスト実行 ─────────────────────────────────────────────────────
run_request() {
  local base="$1"
  local scenario="$2"

  local url="${base}/${scenario}"
  local req_id="load-$(python3 -c "import time; print(int(time.time()*1000))")-${RANDOM}"
  local start=$(python3 -c "import time; print(int(time.time()*1000))")

  echo -n "  ${scenario:-/}: "
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
}

# ── シナリオ配列を実行 ─────────────────────────────────────────────────────
run_scenarios() {
  local base="$1"
  local label="$2"
  shift 2
  local scenarios=("$@")

  echo ""
  echo "=== ${label} (${base}) ==="

  for scenario in "${scenarios[@]}"; do
    run_request "${base}" "${scenario}"
    sleep "${DELAY}"
  done
}

# ── ターゲット存在確認 ─────────────────────────────────────────────────────
check_target() {
  local base="$1"
  curl -sf "${base}/health" > /dev/null 2>&1
}

# ── 対象ベースURLに対してシナリオ実行 ─────────────────────────────────────
run_on_available_targets() {
  local label="$1"
  shift
  local scenarios=("$@")

  if [ -n "${EC2_AS_BASE}" ] && check_target "${EC2_AS_BASE}"; then
    run_scenarios "${EC2_AS_BASE}" "EKS on EC2 (AppSignals) / ${label}" "${scenarios[@]}"
  else
    echo "  [SKIP] EC2 not reachable at ${EC2_AS_BASE}"
  fi

  if [ -n "${FARGATE_AS_BASE}" ] && check_target "${FARGATE_AS_BASE}"; then
    run_scenarios "${FARGATE_AS_BASE}" "EKS on Fargate (AppSignals) / ${label}" "${scenarios[@]}"
  else
    echo "  [SKIP] Fargate AppSignals not reachable at ${FARGATE_AS_BASE}"
  fi

  if [ -n "${EC2_NR_BASE}" ] && check_target "${EC2_NR_BASE}"; then
    run_scenarios "${EC2_NR_BASE}" "EKS on EC2 (NewRelic) / ${label}" "${scenarios[@]}"
  fi

  if [ -n "${FARGATE_NR_BASE}" ] && check_target "${FARGATE_NR_BASE}"; then
    run_scenarios "${FARGATE_NR_BASE}" "EKS on Fargate (NewRelic) / ${label}" "${scenarios[@]}"
  fi
}

# ── ヘルプ ────────────────────────────────────────────────────────────────
print_help() {
  echo ""
  echo "Usage: $0 [scenario]"
  echo ""
  echo "Scenarios:"
  echo "  all                  全シナリオ（デフォルト）"
  echo "  normal-dashboard     ダッシュボード"
  echo "  normal-devices       機器一覧（フィルタ各種）"
  echo "  normal-device-detail 機器詳細 7件（3ホップトレース）"
  echo "  normal-alerts        アラート一覧"
  echo "  slow-query-devices   Slow Query ON後の機器一覧・詳細連打"
  echo "  error-inject-devices Error Inject後の機器一覧連打"
  echo "  alert-storm-alerts   Alert Storm後のアラート一覧"
  echo "  mixed-user-flow      ユーザー回遊（ / → /devices → /devices/id → /alerts → /chaos）"
  echo ""
  echo "Environment variables (.env で設定):"
  echo "  EC2_AS_BASE=http://...      EKS on EC2 + App Signals の URL"
  echo "  FARGATE_AS_BASE=http://...  EKS on Fargate + App Signals の URL"
  echo "  EC2_NR_BASE=http://...      EKS on EC2 + New Relic の URL"
  echo "  FARGATE_NR_BASE=http://...  EKS on Fargate + New Relic の URL"
  echo "  ROUNDS=3                    繰り返し回数"
  echo "  DELAY=1                     リクエスト間隔(秒)"
}

# ── メイン ────────────────────────────────────────────────────────────────
case "${SCENARIO}" in
  -h|--help|help)
    print_help
    exit 0
    ;;

  normal-dashboard)
    echo "====== Normal Dashboard Load ======"
    echo "Rounds: ${ROUNDS}, Delay: ${DELAY}s"
    for round in $(seq 1 "${ROUNDS}"); do
      echo "-- Round ${round}/${ROUNDS} --"
      run_on_available_targets "normal-dashboard" "${NORMAL_DASHBOARD_SCENARIOS[@]}"
    done
    ;;

  normal-devices)
    echo "====== Normal Devices Load ======"
    echo "Rounds: ${ROUNDS}, Delay: ${DELAY}s"
    for round in $(seq 1 "${ROUNDS}"); do
      echo "-- Round ${round}/${ROUNDS} --"
      run_on_available_targets "normal-devices" "${NORMAL_DEVICES_SCENARIOS[@]}"
    done
    ;;

  normal-device-detail)
    echo "====== Normal Device Detail Load (3-hop traces) ======"
    echo "Rounds: ${ROUNDS}, Delay: ${DELAY}s"
    for round in $(seq 1 "${ROUNDS}"); do
      echo "-- Round ${round}/${ROUNDS} --"
      run_on_available_targets "normal-device-detail" "${NORMAL_DEVICE_DETAIL_SCENARIOS[@]}"
    done
    ;;

  normal-alerts)
    echo "====== Normal Alerts Load ======"
    echo "Rounds: ${ROUNDS}, Delay: ${DELAY}s"
    for round in $(seq 1 "${ROUNDS}"); do
      echo "-- Round ${round}/${ROUNDS} --"
      run_on_available_targets "normal-alerts" "${NORMAL_ALERTS_SCENARIOS[@]}"
    done
    ;;

  slow-query-devices)
    echo "====== Slow Query: Devices Load ======"
    echo "Chaos: Slow Query ON が前提です。/chaos 画面から有効にしてから実行してください。"
    echo "Rounds: ${ROUNDS}, Delay: ${DELAY}s"
    for round in $(seq 1 "${ROUNDS}"); do
      echo "-- Round ${round}/${ROUNDS} --"
      run_on_available_targets "slow-query-devices" "${SLOW_QUERY_DEVICES_SCENARIOS[@]}"
    done
    ;;

  error-inject-devices)
    echo "====== Error Inject: Devices Load ======"
    echo "Chaos: Error Inject ON が前提です。/chaos 画面から有効にしてから実行してください。"
    echo "Rounds: ${ROUNDS}, Delay: ${DELAY}s"
    for round in $(seq 1 "${ROUNDS}"); do
      echo "-- Round ${round}/${ROUNDS} --"
      run_on_available_targets "error-inject-devices" "${ERROR_INJECT_DEVICES_SCENARIOS[@]}"
    done
    ;;

  alert-storm-alerts)
    echo "====== Alert Storm: Alerts Load ======"
    echo "Chaos: Alert Storm を実行済みの前提です。"
    echo "Rounds: ${ROUNDS}, Delay: ${DELAY}s"
    for round in $(seq 1 "${ROUNDS}"); do
      echo "-- Round ${round}/${ROUNDS} --"
      run_on_available_targets "alert-storm-alerts" "${ALERT_STORM_ALERTS_SCENARIOS[@]}"
    done
    ;;

  mixed-user-flow)
    echo "====== Mixed User Flow ======"
    echo "  / → /devices → /devices/TKY-CORE-001 → /alerts → /chaos"
    echo "Rounds: ${ROUNDS}, Delay: ${DELAY}s"
    for round in $(seq 1 "${ROUNDS}"); do
      echo "-- Round ${round}/${ROUNDS} --"
      run_on_available_targets "mixed-user-flow" "${MIXED_USER_FLOW_SCENARIOS[@]}"
    done
    ;;

  all|*)
    echo "======================================================"
    echo " NetWatch Load Generator — All Scenarios"
    echo " Rounds: ${ROUNDS}, Delay: ${DELAY}s"
    echo "======================================================"

    for round in $(seq 1 "${ROUNDS}"); do
      echo ""
      echo "====== Round ${round}/${ROUNDS} ======"

      if check_target "${EC2_AS_BASE}"; then
        run_scenarios "${EC2_AS_BASE}" "EKS on EC2 (AppSignals)" "${ALL_SCENARIOS[@]}"
      else
        echo "  [SKIP] EC2_AS_BASE not reachable at ${EC2_AS_BASE}. Set EC2_AS_BASE in .env"
      fi

      if check_target "${FARGATE_AS_BASE}"; then
        run_scenarios "${FARGATE_AS_BASE}" "EKS on Fargate (AppSignals)" "${ALL_SCENARIOS[@]}"
      else
        echo "  [SKIP] FARGATE_AS_BASE not reachable at ${FARGATE_AS_BASE}"
      fi

      if [ -n "${EC2_NR_BASE}" ] && check_target "${EC2_NR_BASE}"; then
        run_scenarios "${EC2_NR_BASE}" "EKS on EC2 (NewRelic)" "${ALL_SCENARIOS[@]}"
      elif [ -z "${EC2_NR_BASE}" ]; then
        echo "  [SKIP] EC2_NR_BASE not set"
      fi

      if [ -n "${FARGATE_NR_BASE}" ] && check_target "${FARGATE_NR_BASE}"; then
        run_scenarios "${FARGATE_NR_BASE}" "EKS on Fargate (NewRelic)" "${ALL_SCENARIOS[@]}"
      elif [ -z "${FARGATE_NR_BASE}" ]; then
        echo "  [SKIP] FARGATE_NR_BASE not set"
      fi

      if [ "${round}" -lt "${ROUNDS}" ]; then
        echo ""
        echo "  Waiting ${DELAY}s before next round..."
        sleep "${DELAY}"
      fi
    done
    ;;
esac

echo ""
echo "======================================================"
echo " Load generation complete!"
echo " Check Application Signals:"
echo "   https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services"
echo "======================================================"
