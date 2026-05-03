#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CLUSTER_NAME="${CLUSTER_NAME:-obs-poc}"
SCOPE="${1:-all}"

delete_log_group() {
  local log_group="$1"
  local output

  output="$(aws logs delete-log-group \
    --region "${AWS_REGION}" \
    --log-group-name "${log_group}" 2>&1)" && {
      echo "  Deleted log group: ${log_group}"
      return 0
    }

  if grep -q "ResourceNotFoundException" <<< "${output}"; then
    return 0
  fi

  echo "  Failed to delete log group: ${log_group}"
  echo "${output}"
  return 1
}

delete_log_groups_by_prefix() {
  local prefix="$1"
  local log_groups

  log_groups="$(aws logs describe-log-groups \
    --region "${AWS_REGION}" \
    --log-group-name-prefix "${prefix}" \
    --query "logGroups[].logGroupName" \
    --output text 2>/dev/null || true)"

  if [ -z "${log_groups}" ] || [ "${log_groups}" = "None" ]; then
    return 0
  fi

  for log_group in ${log_groups}; do
    delete_log_group "${log_group}"
  done
}

delete_alarms_matching() {
  local pattern="$1"
  local alarm_names=()
  local names

  names="$(aws cloudwatch describe-alarms \
    --region "${AWS_REGION}" \
    --query "MetricAlarms[].AlarmName" \
    --output text 2>/dev/null || true)"

  if [ -z "${names}" ] || [ "${names}" = "None" ]; then
    return 0
  fi

  for name in ${names}; do
    if [[ "${name}" == *"${pattern}"* ]]; then
      alarm_names+=("${name}")
    fi
  done

  if [ "${#alarm_names[@]}" -eq 0 ]; then
    return 0
  fi

  aws cloudwatch delete-alarms \
    --region "${AWS_REGION}" \
    --alarm-names "${alarm_names[@]}" >/dev/null
  printf '  Deleted alarm: %s\n' "${alarm_names[@]}"
}

delete_dashboard() {
  local dashboard_name="$1"
  aws cloudwatch delete-dashboards \
    --region "${AWS_REGION}" \
    --dashboard-names "${dashboard_name}" >/dev/null 2>&1 && \
      echo "  Deleted dashboard: ${dashboard_name}" || true
}

delete_metric_stream() {
  local stream_name="$1"
  aws cloudwatch delete-metric-stream \
    --region "${AWS_REGION}" \
    --name "${stream_name}" >/dev/null 2>&1 && \
      echo "  Deleted metric stream: ${stream_name}" || true
}

delete_slo_matching() {
  local pattern="$1"
  local slo_arns

  slo_arns="$(aws application-signals list-service-level-objectives \
    --region "${AWS_REGION}" \
    --query "SloSummaries[?contains(Name, \`${pattern}\`)].Arn" \
    --output text 2>/dev/null || true)"

  if [ -z "${slo_arns}" ] || [ "${slo_arns}" = "None" ]; then
    return 0
  fi

  for arn in ${slo_arns}; do
    aws application-signals delete-service-level-objective \
      --region "${AWS_REGION}" \
      --id "${arn}" >/dev/null 2>&1 && \
        echo "  Deleted Application Signals SLO: ${arn}" || true
  done
}

cleanup_appsignals_shared_data() {
  # Application Signals stores EMF data in one regional log group, not one log
  # group per Kubernetes namespace. Deleting this clears App Signals history for
  # this PoC account/region and lets service-map data age out cleanly.
  delete_log_group "/aws/application-signals/data"
}

cleanup_scope_logs() {
  case "${SCOPE}" in
    ec2-appsignals)
      delete_log_group "/obs-poc/eks-ec2-appsignals/application"
      cleanup_appsignals_shared_data
      ;;
    fargate-appsignals)
      delete_log_group "/obs-poc/eks-fargate-appsignals/application"
      cleanup_appsignals_shared_data
      ;;
    ec2-newrelic)
      ;;
    fargate-newrelic)
      ;;
    all)
      delete_log_group "/aws/eks/${CLUSTER_NAME}/cluster"
      delete_log_group "/aws/eks/${CLUSTER_NAME}/fluent-bit"
      delete_log_group "/aws/containerinsights/${CLUSTER_NAME}/performance"
      delete_log_group "/aws/containerinsights/${CLUSTER_NAME}/application"
      delete_log_group "/aws/containerinsights/${CLUSTER_NAME}/dataplane"
      delete_log_group "/aws/containerinsights/${CLUSTER_NAME}/host"
      delete_log_group "/aws/synthetics/${CLUSTER_NAME}-canary"
      delete_log_group "/obs-poc/eks-ec2-appsignals/application"
      delete_log_group "/obs-poc/eks-fargate-appsignals/application"
      cleanup_appsignals_shared_data
      delete_log_groups_by_prefix "/aws/lambda/cwsyn-${CLUSTER_NAME}-health-check"
      delete_log_groups_by_prefix "/aws/rum/${CLUSTER_NAME}"
      ;;
    *)
      echo "Usage: $0 [all|ec2-appsignals|fargate-appsignals|ec2-newrelic|fargate-newrelic]" >&2
      exit 2
      ;;
  esac
}

echo "==> Cleaning CloudWatch observability data (${SCOPE})..."
cleanup_scope_logs

case "${SCOPE}" in
  all)
    delete_dashboard "${CLUSTER_NAME}-observability-poc"
    delete_metric_stream "${CLUSTER_NAME}-newrelic"
    delete_alarms_matching "${CLUSTER_NAME}"
    delete_alarms_matching "obs-poc"
    delete_alarms_matching "device-api-slow-query-custom"
    delete_slo_matching "${CLUSTER_NAME}"
    delete_slo_matching "obs-poc"
    ;;
  ec2-appsignals)
    delete_alarms_matching "${CLUSTER_NAME}-high-latency-ec2"
    delete_alarms_matching "${CLUSTER_NAME}-high-error-rate-ec2"
    delete_alarms_matching "${CLUSTER_NAME}-pod-cpu-high-ec2"
    delete_alarms_matching "obs-poc-device-api"
    delete_alarms_matching "obs-poc-pod-restart"
    delete_alarms_matching "device-api-slow-query-custom"
    ;;
  fargate-appsignals)
    delete_alarms_matching "${CLUSTER_NAME}-high-latency-fargate"
    delete_alarms_matching "${CLUSTER_NAME}-high-error-rate-fargate"
    delete_alarms_matching "obs-poc-fargate"
    ;;
esac

cat <<'EOF'
  Note: CloudWatch metric datapoints and X-Ray traces do not have a general
  immediate delete API. After log groups, alarms, dashboards, and producers are
  removed, those time-series/traces stop receiving data and age out by AWS
  retention. Application Signals service-map entries can also remain visible
  for a while after the backing log data is deleted.
EOF
