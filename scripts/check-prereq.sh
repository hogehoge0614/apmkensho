#!/usr/bin/env bash
# Check that all required tools are installed and configured
set -euo pipefail

PASS=0
FAIL=0

check() {
  local name="$1"
  local cmd="$2"
  if eval "${cmd}" > /dev/null 2>&1; then
    echo "  [OK]   ${name}"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] ${name}"
    FAIL=$((FAIL+1))
  fi
}

echo ""
echo "======================================================"
echo " Observability PoC — Prerequisites Check"
echo "======================================================"
echo ""
echo "--- CLI Tools ---"
check "aws cli"    "aws --version"
check "kubectl"    "kubectl version --client"
check "helm"       "helm version --short"
check "docker"     "docker info"
check "terraform"  "terraform version"
check "jq"         "jq --version"
check "curl"       "curl --version"
check "python3"    "python3 --version"

echo ""
echo "--- AWS Auth ---"
check "aws credentials" "aws sts get-caller-identity"

echo ""
echo "--- EKS ---"
CLUSTER_NAME="${CLUSTER_NAME:-obs-poc}"
check "kubeconfig (${CLUSTER_NAME})" "kubectl get nodes --request-timeout=5s"

echo ""
echo "--- .env ---"
if [ -f ".env" ]; then
  echo "  [OK]   .env exists"
  PASS=$((PASS+1))
else
  echo "  [FAIL] .env not found — run: cp .env.example .env && vi .env"
  FAIL=$((FAIL+1))
fi

echo ""
echo "======================================================"
if [ "${FAIL}" -eq 0 ]; then
  echo " All checks passed (${PASS}/${PASS})"
else
  echo " ${FAIL} check(s) FAILED — fix before proceeding"
fi
echo "======================================================"
echo ""

[ "${FAIL}" -eq 0 ]
