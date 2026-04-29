#!/usr/bin/env bash
set -euo pipefail
PORT="${PORT:-8080}"
echo "==> Port-forwarding demo-ec2/frontend-ui to localhost:${PORT}"
echo "    Open: http://localhost:${PORT}"
echo "    Press Ctrl+C to stop"
echo ""
kubectl port-forward svc/frontend-ui -n demo-ec2 "${PORT}:8000"
