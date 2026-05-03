#!/usr/bin/env bash
# Enable CloudWatch RUM for netwatch-ui in an App Signals namespace.
# Usage: ./scripts/enable-rum.sh [eks-ec2-appsignals|eks-fargate-appsignals]
# Prerequisites: CW_RUM_APP_MONITOR_ID and CW_RUM_IDENTITY_POOL_ID set in .env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
ECR_REGISTRY="${ECR_REGISTRY:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com}"
NS="${1:-eks-ec2-appsignals}"

case "${NS}" in
  eks-ec2-appsignals)
    MANIFEST="${ROOT_DIR}/k8s/eks-ec2-appsignals/netwatch-ui.yaml"
    ;;
  eks-fargate-appsignals)
    MANIFEST="${ROOT_DIR}/k8s/eks-fargate-appsignals/netwatch-ui.yaml"
    ;;
  *)
    echo "[ERROR] Unsupported namespace for CloudWatch RUM: ${NS}"
    echo "Supported: eks-ec2-appsignals, eks-fargate-appsignals"
    exit 1
    ;;
esac

if [ -z "${CW_RUM_APP_MONITOR_ID:-}" ] || [ -z "${CW_RUM_IDENTITY_POOL_ID:-}" ]; then
  echo "[ERROR] RUM vars not set in .env. Run:"
  echo "  terraform -chdir=infra/terraform output rum_app_monitor_id"
  echo "  terraform -chdir=infra/terraform output cognito_identity_pool_id"
  echo "Then add them to .env and re-run."
  exit 1
fi

echo "==> Enabling CloudWatch RUM in ${NS}..."
echo "  App Monitor ID : ${CW_RUM_APP_MONITOR_ID}"
echo "  Identity Pool  : ${CW_RUM_IDENTITY_POOL_ID}"
echo "  Region         : ${CW_RUM_REGION:-ap-northeast-1}"

sed \
  -e "s|\${ECR_REGISTRY}|${ECR_REGISTRY}|g" \
  -e "s|\${CW_RUM_APP_MONITOR_ID}|${CW_RUM_APP_MONITOR_ID}|g" \
  -e "s|\${CW_RUM_IDENTITY_POOL_ID}|${CW_RUM_IDENTITY_POOL_ID}|g" \
  -e "s|\${CW_RUM_REGION}|${CW_RUM_REGION:-ap-northeast-1}|g" \
  "${MANIFEST}" | kubectl apply -f -

kubectl rollout restart deployment/netwatch-ui -n "${NS}"
kubectl rollout status deployment/netwatch-ui -n "${NS}" --timeout=120s

echo ""
echo "Done. RUM snippet is now injected."
echo "Open the app and visit /rum-test to verify the AwsRumClient is initialized."
echo "Console: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#rum:appMonitorList"
