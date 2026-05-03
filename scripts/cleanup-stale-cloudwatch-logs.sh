#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CLUSTER_NAME="${CLUSTER_NAME:-obs-poc}"
CLEAN_STALE_CLOUDWATCH_LOGS="${CLEAN_STALE_CLOUDWATCH_LOGS:-true}"

if [ "${CLEAN_STALE_CLOUDWATCH_LOGS}" != "true" ]; then
  echo "  Skipping stale CloudWatch Log Groups cleanup (CLEAN_STALE_CLOUDWATCH_LOGS=${CLEAN_STALE_CLOUDWATCH_LOGS})."
  exit 0
fi

describe_output="$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" 2>&1)" && {
    echo "  EKS cluster '${CLUSTER_NAME}' exists; not deleting CloudWatch Log Groups."
    exit 0
  }

if ! grep -q "ResourceNotFoundException" <<< "${describe_output}"; then
  echo "  Cannot confirm EKS cluster '${CLUSTER_NAME}' is absent; refusing to delete CloudWatch Log Groups."
  echo "  aws eks describe-cluster output:"
  echo "${describe_output}"
  exit 1
fi

log_groups=(
  "/aws/eks/${CLUSTER_NAME}/cluster"
  "/aws/eks/${CLUSTER_NAME}/fluent-bit"
  "/aws/containerinsights/${CLUSTER_NAME}/performance"
  "/aws/containerinsights/${CLUSTER_NAME}/application"
  "/aws/containerinsights/${CLUSTER_NAME}/dataplane"
  "/aws/containerinsights/${CLUSTER_NAME}/host"
  "/aws/synthetics/${CLUSTER_NAME}-canary"
  "/aws/application-signals/data"
  "/obs-poc/eks-ec2-appsignals/application"
  "/obs-poc/eks-fargate-appsignals/application"
)

deleted=0
for log_group in "${log_groups[@]}"; do
  delete_output="$(aws logs delete-log-group \
    --log-group-name "${log_group}" \
    --region "${AWS_REGION}" 2>&1)" && {
      echo "  Deleted stale log group: ${log_group}"
      deleted=$((deleted + 1))
      continue
    }

  if grep -q "ResourceNotFoundException" <<< "${delete_output}"; then
    continue
  fi

  echo "  Failed to delete log group: ${log_group}"
  echo "${delete_output}"
  exit 1
done

if [ "${deleted}" -eq 0 ]; then
  echo "  No stale CloudWatch Log Groups found."
else
  echo "  Deleted ${deleted} stale CloudWatch Log Group(s)."
fi
