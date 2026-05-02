#!/usr/bin/env bash
set -euo pipefail
PORT="${PORT:-8081}"
echo "==> Port-forwarding demo-fargate/netwatch-ui to localhost:${PORT}"
echo "    Open: http://localhost:${PORT}"
echo "    Press Ctrl+C to stop"
echo ""
kubectl port-forward svc/netwatch-ui -n demo-fargate "${PORT}:8000"
