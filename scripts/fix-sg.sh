#!/usr/bin/env bash
set -euo pipefail

REGION="ap-northeast-1"
OLD_SG="sg-08a8097971dee9f9b"
TEMP_SG="${1:?Usage: fix-sg.sh <temp-sg-id>}"

VPCES=(
  vpce-0d5d669aa814b8d77
  vpce-030d2af295e146320
  vpce-08682274bd16cef06
  vpce-049b2b0438a938a79
  vpce-07d6cee9608b03d0c
  vpce-066e543ad566fe7e5
)

for VPCE in "${VPCES[@]}"; do
  echo "==> $VPCE: adding $TEMP_SG and removing $OLD_SG"
  aws ec2 modify-vpc-endpoint \
    --vpc-endpoint-id "$VPCE" \
    --add-security-group-ids "$TEMP_SG" \
    --remove-security-group-ids "$OLD_SG" \
    --region "$REGION"
done

echo "Done."
