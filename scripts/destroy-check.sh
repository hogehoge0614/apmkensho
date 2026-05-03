#!/usr/bin/env bash

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CLUSTER_NAME="${CLUSTER_NAME:-obs-poc}"

echo "======================================================"
echo " Post-Destroy Resource Check"
echo " Verify no chargeable resources remain"
echo "======================================================"

echo ""
echo "=== EKS Clusters ==="
aws eks list-clusters --region "${AWS_REGION}" \
  --query "clusters" --output table 2>/dev/null || echo "  Cannot query"

echo ""
echo "=== EC2 Instances (running) ==="
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --filters "Name=instance-state-name,Values=running" \
            "Name=tag:Project,Values=obs-poc" \
  --query "Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,State:State.Name}" \
  --output table 2>/dev/null || echo "  Cannot query"

echo ""
echo "=== VPCs with obs-poc tag ==="
aws ec2 describe-vpcs \
  --region "${AWS_REGION}" \
  --filters "Name=tag:Project,Values=obs-poc" \
  --query "Vpcs[].VpcId" \
  --output table 2>/dev/null || echo "  Cannot query"

echo ""
echo "=== VPC Interface Endpoints ==="
aws ec2 describe-vpc-endpoints \
  --region "${AWS_REGION}" \
  --filters "Name=tag:Project,Values=obs-poc" \
  --query "VpcEndpoints[].{ID:VpcEndpointId,Type:VpcEndpointType,State:State}" \
  --output table 2>/dev/null || echo "  Cannot query"

echo ""
echo "=== CloudWatch Log Groups ==="
aws logs describe-log-groups \
  --region "${AWS_REGION}" \
  --log-group-name-prefix "/obs-poc" \
  --query "logGroups[].logGroupName" \
  --output table 2>/dev/null

aws logs describe-log-groups \
  --region "${AWS_REGION}" \
  --log-group-name-prefix "/aws/eks/${CLUSTER_NAME}" \
  --query "logGroups[].logGroupName" \
  --output table 2>/dev/null

aws logs describe-log-groups \
  --region "${AWS_REGION}" \
  --log-group-name-prefix "/aws/containerinsights/${CLUSTER_NAME}" \
  --query "logGroups[].logGroupName" \
  --output table 2>/dev/null

aws logs describe-log-groups \
  --region "${AWS_REGION}" \
  --log-group-name-prefix "/aws/synthetics/${CLUSTER_NAME}" \
  --query "logGroups[].logGroupName" \
  --output table 2>/dev/null

aws logs describe-log-groups \
  --region "${AWS_REGION}" \
  --log-group-name-prefix "/aws/application-signals" \
  --query "logGroups[].logGroupName" \
  --output table 2>/dev/null

echo ""
echo "=== CloudWatch Alarms (obs-poc) ==="
aws cloudwatch describe-alarms \
  --region "${AWS_REGION}" \
  --query "MetricAlarms[?contains(AlarmName, '${CLUSTER_NAME}') || contains(AlarmName, 'obs-poc') || contains(AlarmName, 'device-api-slow-query-custom')].AlarmName" \
  --output table 2>/dev/null || echo "  Cannot query"

echo ""
echo "=== CloudWatch Dashboards (obs-poc) ==="
aws cloudwatch list-dashboards \
  --region "${AWS_REGION}" \
  --query "DashboardEntries[?contains(DashboardName, '${CLUSTER_NAME}') || contains(DashboardName, 'obs-poc')].DashboardName" \
  --output table 2>/dev/null || echo "  Cannot query"

echo ""
echo "=== CloudWatch Metric Streams (obs-poc) ==="
aws cloudwatch list-metric-streams \
  --region "${AWS_REGION}" \
  --query "Entries[?contains(Name, '${CLUSTER_NAME}') || contains(Name, 'obs-poc')].Name" \
  --output table 2>/dev/null || echo "  Cannot query"

echo ""
echo "=== CloudWatch Synthetics Canaries ==="
aws synthetics describe-canaries \
  --region "${AWS_REGION}" \
  --query "Canaries[].{Name:Name,State:Status.State}" \
  --output table 2>/dev/null || echo "  None found"

echo ""
echo "=== Kinesis Firehose Streams ==="
aws firehose list-delivery-streams \
  --region "${AWS_REGION}" \
  --query "DeliveryStreamNames" \
  --output table 2>/dev/null || echo "  None found"

echo ""
echo "=== S3 Buckets ==="
aws s3 ls 2>/dev/null | grep "${CLUSTER_NAME}" || echo "  No matching buckets"

echo ""
echo "=== ECR Repositories ==="
aws ecr describe-repositories \
  --region "${AWS_REGION}" \
  --query "repositories[?contains(repositoryName, 'obs-poc')].repositoryName" \
  --output table 2>/dev/null || echo "  None found"

echo ""
echo "=== IAM Roles ==="
aws iam list-roles \
  --query "Roles[?contains(RoleName, '${CLUSTER_NAME}')].RoleName" \
  --output table 2>/dev/null || echo "  Cannot query"

echo ""
echo "======================================================"
echo " If any resources remain above, delete them manually:"
echo "   aws eks delete-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}"
echo "   aws ecr delete-repository --force --repository-name obs-poc/<svc>"
echo "   aws s3 rb s3://<bucket-name> --force"
echo "   aws logs delete-log-group --log-group-name /obs-poc/..."
echo "   aws logs delete-log-group --log-group-name /aws/containerinsights/${CLUSTER_NAME}/..."
echo "   aws logs delete-log-group --log-group-name /aws/application-signals/data"
echo ""
echo " CloudWatch metric datapoints and X-Ray traces cannot be immediately purged"
echo " by a general delete API. They stop updating after producers/log groups are"
echo " deleted and age out according to AWS retention."
echo ""
echo " Or re-run: cd infra/terraform && terraform destroy -auto-approve"
echo "======================================================"
