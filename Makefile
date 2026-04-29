# ============================================================
# Observability PoC - Makefile
# CloudWatch + Application Signals vs New Relic Full Stack
# ============================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Load .env if present
-include .env
export

AWS_REGION ?= ap-northeast-1
CLUSTER_NAME ?= obs-poc
NS ?= demo-ec2
SVC ?= frontend-ui
TAIL ?= 50
AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
ECR_REGISTRY ?= $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

TF_DIR := infra/terraform
SCRIPTS_DIR := scripts

.PHONY: help up build-push deploy-ec2 deploy-fargate deploy-newrelic \
        install-cloudwatch-full install-newrelic-full \
        create-secrets load status logs compare-check \
        port-forward-ec2 port-forward-fargate port-forward-newrelic down \
        tf-init tf-plan tf-apply tf-destroy destroy-check

# ============================================================
# Help
# ============================================================
help:
	@echo ""
	@echo "  Observability PoC"
	@echo "  AWS CloudWatch Application Signals  vs  New Relic Full Stack"
	@echo "  Zero app code changes — operator-based auto-injection on both sides"
	@echo ""
	@echo "  Prerequisites: aws cli, kubectl, helm, docker, terraform"
	@echo "  Copy .env.example to .env and fill in values first."
	@echo ""
	@echo "  Quick Start:"
	@echo "    1.  make up                       # Create EKS + AWS resources"
	@echo "    2.  make create-secrets           # Create K8s secrets"
	@echo "    3.  make build-push               # Build & push Docker images"
	@echo "    4.  make install-cloudwatch-full  # Setup CloudWatch stack"
	@echo "    5.  make deploy-ec2               # Deploy apps (CloudWatch path, EC2)"
	@echo "    6.  make deploy-fargate           # Deploy apps (CloudWatch path, Fargate)"
	@echo "    7.  make install-newrelic-full    # Setup New Relic stack"
	@echo "    8.  make deploy-newrelic          # Deploy apps (New Relic path, EC2)"
	@echo "    9.  make port-forward-ec2         # CloudWatch path UI -> http://localhost:8080"
	@echo "   10.  make port-forward-newrelic    # New Relic path UI  -> http://localhost:8082"
	@echo "   11.  make load                     # Generate trace traffic (CloudWatch path)"
	@echo "   12.  make compare-check            # Show comparison guide"
	@echo "   13.  make down                     # Destroy all resources"
	@echo ""
	@echo "  Instrumentation:"
	@echo "    CloudWatch: OTel Operator (CW addon) injects OTel SDK -> ADOT -> App Signals"
	@echo "    New Relic:  k8s-agents-operator    injects NR agent   -> NR APM"
	@echo "    Same app image. Same namespace pattern. Independent pipelines."
	@echo ""
	@echo "  Maintenance:"
	@echo "    make status          Show cluster/pod/addon status"
	@echo "    make logs [NS=demo-ec2] [SVC=frontend-ui]   Tail structured logs"
	@echo "    make destroy-check   Verify no resources remain after destroy"
	@echo ""

# ============================================================
# Terraform
# ============================================================
tf-init:
	@echo "==> Initializing Terraform..."
	@cd $(TF_DIR) && terraform init

tf-plan:
	@echo "==> Planning Terraform..."
	@cd $(TF_DIR) && terraform plan \
		-var="cluster_name=$(CLUSTER_NAME)" \
		-var="new_relic_license_key=$(NEW_RELIC_LICENSE_KEY)" \
		-var="new_relic_account_id=$(NEW_RELIC_ACCOUNT_ID)"

tf-apply:
	@echo "==> Applying Terraform..."
	@cd $(TF_DIR) && terraform apply -auto-approve \
		-var="cluster_name=$(CLUSTER_NAME)" \
		-var="new_relic_license_key=$(NEW_RELIC_LICENSE_KEY)" \
		-var="new_relic_account_id=$(NEW_RELIC_ACCOUNT_ID)"

# ============================================================
# Core lifecycle
# ============================================================
up: tf-init tf-apply
	@echo ""
	@echo "==> Updating kubeconfig..."
	@aws eks update-kubeconfig \
		--region $(AWS_REGION) \
		--name $(CLUSTER_NAME)
	@echo ""
	@echo "==> Verifying cluster..."
	@kubectl get nodes
	@echo ""
	@echo "EKS cluster ready. Run 'make create-secrets' then 'make build-push'."

build-push:
	@$(SCRIPTS_DIR)/build-push.sh

deploy-ec2:
	@$(SCRIPTS_DIR)/deploy-ec2.sh

deploy-fargate:
	@$(SCRIPTS_DIR)/deploy-fargate.sh

deploy-newrelic:
	@$(SCRIPTS_DIR)/deploy-newrelic.sh

install-cloudwatch-full:
	@$(SCRIPTS_DIR)/install-cloudwatch-full.sh

install-newrelic-full:
	@$(SCRIPTS_DIR)/install-newrelic-full.sh

create-secrets:
	@$(SCRIPTS_DIR)/create-secrets.sh

load:
	@$(SCRIPTS_DIR)/load.sh

status:
	@$(SCRIPTS_DIR)/status.sh

logs:
	@$(SCRIPTS_DIR)/logs.sh $(NS) $(SVC) $(TAIL)

compare-check:
	@$(SCRIPTS_DIR)/compare-check.sh

port-forward-ec2:
	@$(SCRIPTS_DIR)/port-forward-ec2.sh

port-forward-fargate:
	@$(SCRIPTS_DIR)/port-forward-fargate.sh

port-forward-newrelic:
	@$(SCRIPTS_DIR)/port-forward-newrelic.sh

# ============================================================
# Destroy
# ============================================================
down:
	@echo ""
	@echo "======================================================"
	@echo " Destroying Observability PoC Resources"
	@echo "======================================================"
	@echo ""

	@echo "==> [1/5] Stopping CloudWatch Synthetics canaries..."
	@aws synthetics stop-canary --name $(CLUSTER_NAME)-health-check \
		--region $(AWS_REGION) 2>/dev/null || true

	@echo ""
	@echo "==> [2/5] Removing Helm releases..."
	@helm uninstall nri-bundle -n newrelic 2>/dev/null || true

	@echo ""
	@echo "==> [3/5] Deleting Kubernetes resources..."
	@kubectl delete namespace demo-ec2 --timeout=60s 2>/dev/null || true
	@kubectl delete namespace demo-fargate --timeout=60s 2>/dev/null || true
	@kubectl delete namespace demo-newrelic --timeout=60s 2>/dev/null || true
	@kubectl delete namespace newrelic --timeout=60s 2>/dev/null || true
	@kubectl delete namespace aws-observability --timeout=60s 2>/dev/null || true

	@echo ""
	@echo "==> [4/5] Running Terraform destroy..."
	@cd $(TF_DIR) && terraform destroy -auto-approve \
		-var="cluster_name=$(CLUSTER_NAME)" \
		-var="new_relic_license_key=$(NEW_RELIC_LICENSE_KEY)" \
		-var="new_relic_account_id=$(NEW_RELIC_ACCOUNT_ID)" \
		2>/dev/null || echo "  Terraform destroy completed with some errors - check manually"

	@echo ""
	@echo "==> [5/5] Running destroy-check..."
	@$(SCRIPTS_DIR)/destroy-check.sh

	@echo ""
	@echo "======================================================"
	@echo " Destroy complete."
	@echo " Run 'make destroy-check' again to verify cleanup."
	@echo "======================================================"

destroy-check:
	@$(SCRIPTS_DIR)/destroy-check.sh

tf-destroy:
	@cd $(TF_DIR) && terraform destroy -auto-approve \
		-var="cluster_name=$(CLUSTER_NAME)" \
		-var="new_relic_license_key=$(NEW_RELIC_LICENSE_KEY)" \
		-var="new_relic_account_id=$(NEW_RELIC_ACCOUNT_ID)"
