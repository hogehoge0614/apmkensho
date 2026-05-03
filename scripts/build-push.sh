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
DOCKER_RETRIES="${DOCKER_RETRIES:-3}"
DOCKER_RETRY_DELAY="${DOCKER_RETRY_DELAY:-10}"

SERVICES=(
  "netwatch-ui"
  "device-api"
  "alert-api"
  "metrics-collector"
)

ensure_docker_running() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  if [ "$(uname -s)" = "Darwin" ] && [ -d "/Applications/Docker.app" ]; then
    echo "==> Docker daemon is not running. Starting Docker Desktop..."
    open -a Docker

    for _ in $(seq 1 60); do
      if docker info >/dev/null 2>&1; then
        echo "==> Docker is ready."
        return 0
      fi
      sleep 2
    done
  fi

  echo "ERROR: Docker daemon is not running."
  echo "Start Docker Desktop, then re-run: make build-push"
  exit 1
}

ensure_docker_running

retry() {
  local attempt=1
  local exit_code=0

  while [ "${attempt}" -le "${DOCKER_RETRIES}" ]; do
    if "$@"; then
      return 0
    fi

    exit_code=$?
    if [ "${attempt}" -eq "${DOCKER_RETRIES}" ]; then
      break
    fi

    echo "  [WARN] Command failed with exit code ${exit_code}. Retrying in ${DOCKER_RETRY_DELAY}s (${attempt}/${DOCKER_RETRIES})..."
    sleep "${DOCKER_RETRY_DELAY}"
    ensure_docker_running
    attempt=$((attempt + 1))
  done

  return "${exit_code}"
}

docker_login() {
  aws ecr get-login-password --region "${AWS_REGION}" | \
    docker login --username AWS --password-stdin "${ECR_REGISTRY}"
}

echo "==> Logging in to ECR: ${ECR_REGISTRY}"
retry docker_login

for svc in "${SERVICES[@]}"; do
  echo ""
  echo "==> Building ${svc}..."
  docker build \
    --platform linux/amd64 \
    -t "${ECR_REGISTRY}/${CLUSTER_NAME}/${svc}:${TAG}" \
    "${ROOT_DIR}/apps/${svc}"

  echo "==> Pushing ${svc}..."
  retry docker push "${ECR_REGISTRY}/${CLUSTER_NAME}/${svc}:${TAG}"
  echo "    Pushed: ${ECR_REGISTRY}/${CLUSTER_NAME}/${svc}:${TAG}"
done

echo ""
echo "==> Mirroring ADOT Collector image to private ECR (for Fargate access via ECR VPC endpoint)..."
ADOT_SRC="public.ecr.aws/aws-observability/aws-otel-collector:latest"
ADOT_DST="${ECR_REGISTRY}/${CLUSTER_NAME}/adot-collector:latest"
retry docker pull --platform linux/amd64 "${ADOT_SRC}"
docker tag "${ADOT_SRC}" "${ADOT_DST}"
retry docker push "${ADOT_DST}"
echo "    Pushed: ${ADOT_DST}"

echo ""
echo "All images pushed successfully."
echo "ECR_REGISTRY=${ECR_REGISTRY}"
