#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CLUSTER_NAME="${CLUSTER_NAME:-obs-poc}"
TF_DIR="${TF_DIR:-infra/terraform}"

log_groups=(
  "aws_cloudwatch_log_group.eks_control_plane|/aws/eks/${CLUSTER_NAME}/cluster"
  "aws_cloudwatch_log_group.container_insights|/aws/containerinsights/${CLUSTER_NAME}/performance"
  "aws_cloudwatch_log_group.container_insights_application|/aws/containerinsights/${CLUSTER_NAME}/application"
  "aws_cloudwatch_log_group.container_insights_dataplane|/aws/containerinsights/${CLUSTER_NAME}/dataplane"
  "aws_cloudwatch_log_group.container_insights_host|/aws/containerinsights/${CLUSTER_NAME}/host"
  "aws_cloudwatch_log_group.app_ec2|/obs-poc/eks-ec2-appsignals/application"
  "aws_cloudwatch_log_group.app_fargate|/obs-poc/eks-fargate-appsignals/application"
  "aws_cloudwatch_log_group.fluent_bit|/aws/eks/${CLUSTER_NAME}/fluent-bit"
  "aws_cloudwatch_log_group.synthetics|/aws/synthetics/${CLUSTER_NAME}-canary"
)

state_list="$(terraform -chdir="${TF_DIR}" state list 2>/dev/null || true)"
imported=0

for item in "${log_groups[@]}"; do
  address="${item%%|*}"
  log_group="${item#*|}"

  if grep -Fxq "${address}" <<< "${state_list}"; then
    continue
  fi

  existing="$(aws logs describe-log-groups \
    --region "${AWS_REGION}" \
    --log-group-name-prefix "${log_group}" \
    --query "logGroups[?logGroupName==\`${log_group}\`].logGroupName" \
    --output text)"

  if [ -z "${existing}" ] || [ "${existing}" = "None" ]; then
    continue
  fi

  echo "  Importing existing log group: ${log_group}"
  terraform -chdir="${TF_DIR}" import \
    -var="cluster_name=${CLUSTER_NAME}" \
    -var="new_relic_license_key=${NEW_RELIC_LICENSE_KEY:-}" \
    -var="new_relic_account_id=${NEW_RELIC_ACCOUNT_ID:-}" \
    "${address}" \
    "${log_group}" >/dev/null
  imported=$((imported + 1))
done

if [ "${imported}" -eq 0 ]; then
  echo "  No CloudWatch Log Groups needed import."
else
  echo "  Imported ${imported} CloudWatch Log Group(s)."
fi
