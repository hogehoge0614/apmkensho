#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
ECR_REGISTRY="${ECR_REGISTRY:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com}"
CLUSTER_NAME="${CLUSTER_NAME:-obs-poc}"

APP_SIGNALS_FARGATE_ROLE_ARN=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw app_signals_fargate_role_arn 2>/dev/null || echo "")
APP_SIGNALS_EC2_ROLE_ARN=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw app_signals_ec2_role_arn 2>/dev/null || echo "")

echo "==> Creating namespaces..."
sed \
  -e "s|\${APP_SIGNALS_EC2_ROLE_ARN}|${APP_SIGNALS_EC2_ROLE_ARN}|g" \
  -e "s|\${APP_SIGNALS_FARGATE_ROLE_ARN}|${APP_SIGNALS_FARGATE_ROLE_ARN}|g" \
  "${ROOT_DIR}/k8s/namespaces.yaml" | kubectl apply -f -

echo "==> Setting up Fargate Fluent Bit log routing (aws-observability namespace)..."
# Fargate uses Fluent Bit sidecar via ConfigMap in aws-observability namespace
kubectl create namespace aws-observability --dry-run=client -o yaml | kubectl apply -f -

cat <<FBIT | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-logging
  namespace: aws-observability
data:
  flb_log_cw: "true"
  filters.conf: |
    [FILTER]
        Name                parser
        Match               *
        Key_Name            log
        Parser              crio
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Merge_Log           On
        Keep_Log            Off
        Buffer_Size         0
        Kube_Meta_Preloaded_Cache_TTL 300
  output.conf: |
    [OUTPUT]
        Name                cloudwatch_logs
        Match               kube.*
        region              ${AWS_REGION}
        log_group_name      /obs-poc/demo-fargate/application
        log_stream_prefix   fargate-
        log_retention_days  1
        auto_create_group   true
  parsers.conf: |
    [PARSER]
        Name                crio
        Format              Regex
        Regex               ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[^ ]*) ?(?<log>.*)$
        Time_Key            time
        Time_Format         %Y-%m-%dT%H:%M:%S.%L%z
FBIT

echo "==> Deploying Fargate manifests to demo-fargate namespace..."
for manifest in "${ROOT_DIR}/k8s/fargate/"*.yaml; do
  echo "  Applying: $(basename ${manifest})"
  sed "s|\${ECR_REGISTRY}|${ECR_REGISTRY}|g" "${manifest}" | kubectl apply -f -
done

echo ""
echo "==> Waiting for Fargate pods (may take 1-2 min for Fargate node provisioning)..."
kubectl rollout status deployment/frontend-ui -n demo-fargate --timeout=180s || true
kubectl rollout status deployment/backend-for-frontend -n demo-fargate --timeout=180s || true

echo ""
echo "==> Fargate Pods:"
kubectl get pods -n demo-fargate -o wide

echo ""
echo "Done. Use 'make port-forward-fargate' to access the UI."
echo "NOTE: Fargate pods run on virtual nodes - DaemonSet-based agents do not apply."
