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
NS="eks-fargate-appsignals"

APP_SIGNALS_FARGATE_ROLE_ARN=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw app_signals_fargate_role_arn 2>/dev/null || echo "")
APP_SIGNALS_EC2_ROLE_ARN=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw app_signals_ec2_role_arn 2>/dev/null || echo "")

echo "==> Creating namespaces and ServiceAccounts..."
sed \
  -e "s|\${APP_SIGNALS_EC2_ROLE_ARN}|${APP_SIGNALS_EC2_ROLE_ARN}|g" \
  -e "s|\${APP_SIGNALS_FARGATE_ROLE_ARN}|${APP_SIGNALS_FARGATE_ROLE_ARN}|g" \
  "${ROOT_DIR}/k8s/namespaces.yaml" | kubectl apply -f -

echo "==> Setting up Fargate Fluent Bit log routing (aws-observability namespace)..."
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
        log_group_name      /obs-poc/eks-fargate-appsignals/application
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

echo "==> Creating database secret (device-api-db) for ${NS}..."
RDS_ENDPOINT=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw rds_endpoint 2>/dev/null || echo "")
RDS_PASSWORD=$(cd "${ROOT_DIR}/infra/terraform" && terraform output -raw rds_password 2>/dev/null || echo "")

if [ -n "${RDS_ENDPOINT}" ]; then
  DB_URL="postgresql://netwatch:${RDS_PASSWORD}@${RDS_ENDPOINT}/netwatch"
  kubectl create secret generic device-api-db \
    --namespace "${NS}" \
    --from-literal=DATABASE_URL="${DB_URL}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  Secret device-api-db created/updated."
else
  echo "  [WARN] rds_endpoint not found — device-api will fail to start."
fi

echo ""
echo "==> Deploying manifests to ${NS} namespace..."
for manifest in "${ROOT_DIR}/k8s/eks-fargate-appsignals/"*.yaml; do
  echo "  Applying: $(basename ${manifest})"
  sed \
    -e "s|\${ECR_REGISTRY}|${ECR_REGISTRY}|g" \
    -e "s|\${APP_SIGNALS_FARGATE_ROLE_ARN}|${APP_SIGNALS_FARGATE_ROLE_ARN}|g" \
    -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
    -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" \
    -e "s|\${CW_RUM_APP_MONITOR_ID}|${CW_RUM_APP_MONITOR_ID:-}|g" \
    -e "s|\${CW_RUM_IDENTITY_POOL_ID}|${CW_RUM_IDENTITY_POOL_ID:-}|g" \
    -e "s|\${CW_RUM_REGION}|${CW_RUM_REGION:-ap-northeast-1}|g" \
    "${manifest}" | kubectl apply -f -
done

echo ""
echo "==> Waiting for Fargate pods (may take 1-2 min for node provisioning)..."
kubectl rollout status deployment/metrics-collector -n "${NS}" --timeout=180s || true
kubectl rollout status deployment/device-api        -n "${NS}" --timeout=180s || true
kubectl rollout status deployment/alert-api         -n "${NS}" --timeout=180s || true
kubectl rollout status deployment/netwatch-ui       -n "${NS}" --timeout=180s || true

echo ""
echo "==> Pods (${NS}):"
kubectl get pods -n "${NS}" -o wide

echo ""
LB_HOST=$(kubectl get svc netwatch-ui -n "${NS}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "${LB_HOST}" ]; then
  echo "Done. NetWatch UI: http://${LB_HOST}"
  echo "Set FARGATE_AS_BASE=http://${LB_HOST} in .env"
else
  echo "Done. LoadBalancer is provisioning. Run:"
  echo "  kubectl get svc netwatch-ui -n ${NS} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
fi
echo ""
echo "NOTE: Fargate — CloudWatch Agent DaemonSet does not run on virtual nodes."
echo "      OTel SDK sends traces to the namespace-local adot-collector Deployment."
