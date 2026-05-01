#!/usr/bin/env bash
# Enable StatsD custom metrics collection via CloudWatch Agent
# Patches the CloudWatch Agent ConfigMap to add a StatsD listener on UDP 8125
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CUSTOM_METRICS_NAMESPACE="${CUSTOM_METRICS_NAMESPACE:-NetwatchPoC/Custom}"

echo "==> Enabling StatsD custom metrics collection..."
echo "  Namespace : ${CUSTOM_METRICS_NAMESPACE}"
echo "  Port      : UDP 8125"

# Create a ConfigMap with StatsD config for the CloudWatch Agent
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cwagent-statsd-config
  namespace: amazon-cloudwatch
data:
  cwagentconfig.json: |
    {
      "metrics": {
        "namespace": "${CUSTOM_METRICS_NAMESPACE}",
        "metrics_collected": {
          "statsd": {
            "service_address": ":8125",
            "metrics_collection_interval": 60,
            "metrics_aggregation_interval": 300
          }
        }
      }
    }
EOF

echo ""
echo "==> Patching CloudWatch Agent to mount StatsD config..."
# The amazon-cloudwatch-observability addon manages a CloudWatchAgent CR.
# Patch it to merge the StatsD config.
kubectl patch cloudwatchagent cloudwatch-agent \
  -n amazon-cloudwatch \
  --type=merge \
  --patch '{
    "spec": {
      "config": {
        "metrics": {
          "namespace": "'"${CUSTOM_METRICS_NAMESPACE}"'",
          "metrics_collected": {
            "statsd": {
              "service_address": ":8125",
              "metrics_collection_interval": 60,
              "metrics_aggregation_interval": 300
            }
          }
        }
      }
    }
  }' 2>/dev/null && echo "  CloudWatchAgent CR patched." || {
    echo "  [INFO] CloudWatchAgent CR not found. Trying ConfigMap patch..."
    # Fallback: patch the agent ConfigMap directly
    kubectl get configmap amazon-cloudwatch-agent -n amazon-cloudwatch -o json 2>/dev/null | \
      python3 -c "
import sys, json
cm = json.load(sys.stdin)
existing = json.loads(cm['data'].get('cwagentconfig.json','{}'))
statsd = {'service_address':':8125','metrics_collection_interval':60,'metrics_aggregation_interval':300}
existing.setdefault('metrics',{}).setdefault('metrics_collected',{})['statsd'] = statsd
existing['metrics']['namespace'] = '${CUSTOM_METRICS_NAMESPACE}'
cm['data']['cwagentconfig.json'] = json.dumps(existing, indent=2)
print(json.dumps(cm))
" | kubectl apply -f - && echo "  ConfigMap patched." || echo "  [WARN] Could not patch ConfigMap. StatsD may not be active."
  }

echo ""
echo "==> Restarting CloudWatch Agent DaemonSet..."
kubectl rollout restart daemonset/cloudwatch-agent -n amazon-cloudwatch 2>/dev/null || \
  kubectl rollout restart deployment/cloudwatch-agent -n amazon-cloudwatch 2>/dev/null || \
  echo "  [INFO] Could not restart agent — it may restart automatically."

echo ""
echo "Done. StatsD metrics will appear in CloudWatch under namespace: ${CUSTOM_METRICS_NAMESPACE}"
echo ""
echo "Verify with:"
echo "  aws cloudwatch list-metrics --namespace ${CUSTOM_METRICS_NAMESPACE} --region ${AWS_REGION}"
echo ""
echo "Generate test metrics:"
echo "  kubectl exec -n demo-ec2 deploy/netwatch-ui -- python3 -c \\"
echo "    \"import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.sendto(b'netwatch.ui.test:1|c', ('localhost',8125))\""
