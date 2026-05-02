#!/usr/bin/env bash
set -euo pipefail
PORT="${PORT:-8080}"
echo "==> Port-forwarding eks-ec2-appsignals/netwatch-ui to localhost:${PORT}"
echo "    Open: http://localhost:${PORT}"
echo "    Press Ctrl+C to stop"
echo ""
kubectl port-forward svc/netwatch-ui -n eks-ec2-appsignals "${PORT}:8000"
