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
TAG="${1:-latest}"

SERVICES=(
  "netwatch-ui"
  "device-api"
  "alert-api"
  "metrics-collector"
)

echo "==> Logging in to ECR: ${ECR_REGISTRY}"
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"

for svc in "${SERVICES[@]}"; do
  echo ""
  echo "==> Building ${svc}..."
  docker build \
    --platform linux/amd64 \
    -t "${ECR_REGISTRY}/${CLUSTER_NAME}/${svc}:${TAG}" \
    "${ROOT_DIR}/apps/${svc}"

  echo "==> Pushing ${svc}..."
  docker push "${ECR_REGISTRY}/${CLUSTER_NAME}/${svc}:${TAG}"
  echo "    Pushed: ${ECR_REGISTRY}/${CLUSTER_NAME}/${svc}:${TAG}"
done

echo ""
echo "==> Mirroring ADOT Collector image to private ECR (for Fargate access via ECR VPC endpoint)..."
ADOT_SRC="public.ecr.aws/aws-observability/aws-otel-collector:latest"
ADOT_DST="${ECR_REGISTRY}/${CLUSTER_NAME}/adot-collector:latest"
docker pull --platform linux/amd64 "${ADOT_SRC}"
docker tag "${ADOT_SRC}" "${ADOT_DST}"
docker push "${ADOT_DST}"
echo "    Pushed: ${ADOT_DST}"

echo ""
echo "All images pushed successfully."
echo "ECR_REGISTRY=${ECR_REGISTRY}"
