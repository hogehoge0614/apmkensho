#!/usr/bin/env bash
set -euo pipefail
PORT="${PORT:-8082}"
echo "==> Port-forwarding demo-newrelic/netwatch-ui to localhost:${PORT}"
echo "    Open: http://localhost:${PORT}"
echo "    Press Ctrl+C to stop"
echo ""
kubectl port-forward svc/netwatch-ui -n demo-newrelic "${PORT}:8000"
