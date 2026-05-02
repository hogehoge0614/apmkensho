#!/usr/bin/env bash
set -euo pipefail
PORT="${PORT:-8083}"
echo "==> Port-forwarding eks-fargate-newrelic/netwatch-ui to localhost:${PORT}"
echo "    Open: http://localhost:${PORT}"
echo "    Press Ctrl+C to stop"
echo ""
kubectl port-forward svc/netwatch-ui -n eks-fargate-newrelic "${PORT}:8000"
