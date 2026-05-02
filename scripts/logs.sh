#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-demo-ec2}"
SERVICE="${2:-netwatch-ui}"
TAIL="${3:-50}"

echo "==> Logs for ${SERVICE} in ${NAMESPACE} (last ${TAIL} lines)"
echo ""

kubectl logs -n "${NAMESPACE}" \
  -l "app=${SERVICE}" \
  --tail="${TAIL}" \
  --timestamps=true \
  2>/dev/null | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    # Try to pretty-print JSON logs
    try:
        ts_end = line.index(' ', 0, 35)
        ts = line[:ts_end]
        rest = line[ts_end+1:]
        data = json.loads(rest)
        service = data.get('service_name', '')
        endpoint = data.get('endpoint', '')
        status = data.get('status_code', '')
        latency = data.get('latency_ms', '')
        scenario = data.get('scenario', '')
        trace_id = data.get('trace_id', '')
        error = data.get('error_message', '')
        color = '\033[32m' if str(status) == '200' else '\033[31m' if str(status) >= '400' else '\033[33m'
        reset = '\033[0m'
        print(f'{ts} {color}[{service}]{reset} {endpoint} status={status} latency={latency}ms scenario={scenario}', end='')
        if trace_id:
            print(f' trace={trace_id[:16]}...', end='')
        if error:
            print(f' \033[31mERROR: {error}{reset}', end='')
        print()
    except (json.JSONDecodeError, ValueError):
        print(line)
" || kubectl logs -n "${NAMESPACE}" -l "app=${SERVICE}" --tail="${TAIL}"
