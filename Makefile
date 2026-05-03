# ============================================================
# Observability PoC - Makefile
# 4 environments: EKS on EC2/Fargate × App Signals/New Relic
# ============================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

-include .env
export

AWS_REGION    ?= ap-northeast-1
CLUSTER_NAME  ?= obs-poc
NS            ?= eks-ec2-appsignals
SVC           ?= netwatch-ui
TAIL          ?= 50
AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
ECR_REGISTRY  ?= $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

TF_DIR     := infra/terraform
SCRIPTS_DIR := scripts

.PHONY: help \
        check-prereq aws-whoami kube-context \
        up build-push create-secrets \
        ec2-appsignals-deploy ec2-appsignals-verify ec2-appsignals-down \
        ec2-appsignals-enable-rum ec2-appsignals-enable-custom-metrics \
        fargate-appsignals-deploy fargate-appsignals-verify fargate-appsignals-down \
        fargate-appsignals-enable-rum \
        ec2-newrelic-deploy ec2-newrelic-verify ec2-newrelic-down \
        fargate-newrelic-deploy fargate-newrelic-verify fargate-newrelic-down \
        install-cloudwatch-full install-newrelic-full \
        load load-normal load-devices load-detail load-slow load-error load-storm \
        status logs compare-check \
        port-forward-ec2 port-forward-fargate port-forward-newrelic port-forward-fargate-newrelic \
        down tf-init tf-plan tf-apply tf-destroy destroy-check

# ============================================================
# Help
# ============================================================
help:
	@echo ""
	@echo "  NetWatch Observability PoC"
	@echo "  4 environments: EKS on EC2/Fargate × App Signals/New Relic"
	@echo ""
	@echo "  Prerequisites: aws cli, kubectl, helm, docker, terraform"
	@echo "  Setup: cp .env.example .env && vi .env"
	@echo "  Docs: docs/setup.md (セットアップ手順)"
	@echo ""
	@echo "  ┌─────────────────────────────────────────────────────────────────────┐"
	@echo "  │  Environment Matrix                                                 │"
	@echo "  │                                                                     │"
	@echo "  │                  App Signals          New Relic                     │"
	@echo "  │  EKS on EC2    eks-ec2-appsignals   eks-ec2-newrelic               │"
	@echo "  │  EKS on Fargate eks-fargate-appsignals eks-fargate-newrelic (*)    │"
	@echo "  │                                                                     │"
	@echo "  │  (*) APM traces only. Infra Agent (DaemonSet) not available.       │"
	@echo "  └─────────────────────────────────────────────────────────────────────┘"
	@echo ""
	@echo "  ── Shared Setup (run once) ─────────────────────────────────────────────"
	@echo "    make check-prereq             # verify tools & AWS auth"
	@echo "    make up                       # create EKS + resources (~20 min)"
	@echo "    make create-secrets           # create K8s secrets"
	@echo "    make build-push               # build & push images to ECR (~10 min)"
	@echo ""
	@echo "  ── EKS on EC2 + App Signals (eks-ec2-appsignals) ──────────────────────"
	@echo "    make install-cloudwatch-full"
	@echo "    make ec2-appsignals-deploy"
	@echo "    make ec2-appsignals-verify"
	@echo "    make ec2-appsignals-enable-rum"
	@echo "    make ec2-appsignals-enable-custom-metrics"
	@echo "    make ec2-appsignals-down"
	@echo ""
	@echo "  ── EKS on Fargate + App Signals (eks-fargate-appsignals) ──────────────"
	@echo "    make install-cloudwatch-full  # shared with EC2"
	@echo "    make fargate-appsignals-deploy"
	@echo "    make fargate-appsignals-verify"
	@echo "    make fargate-appsignals-enable-rum"
	@echo "    make fargate-appsignals-down"
	@echo ""
	@echo "  ── EKS on EC2 + New Relic (eks-ec2-newrelic) ──────────────────────────"
	@echo "    make install-newrelic-full    # requires NEW_RELIC_LICENSE_KEY in .env"
	@echo "    make ec2-newrelic-deploy"
	@echo "    make ec2-newrelic-verify"
	@echo "    make ec2-newrelic-down"
	@echo ""
	@echo "  ── EKS on Fargate + New Relic (eks-fargate-newrelic) [APM only] ───────"
	@echo "    make install-newrelic-full    # shared with EC2"
	@echo "    make fargate-newrelic-deploy"
	@echo "    make fargate-newrelic-verify"
	@echo "    make fargate-newrelic-down"
	@echo ""
	@echo "  ── Traffic Generation ──────────────────────────────────────────────────"
	@echo "    make load           # all scenarios to all running environments"
	@echo "    make load-normal    # dashboard + device list"
	@echo "    make load-detail    # device detail (3-hop traces)"
	@echo "    make load-slow      # slow query scenario"
	@echo "    make load-error     # error injection scenario"
	@echo "    make load-storm     # alert storm scenario"
	@echo ""
	@echo "  ── Utilities ───────────────────────────────────────────────────────────"
	@echo "    make status                               # all 4 environments"
	@echo "    make logs [NS=eks-ec2-appsignals] [SVC=netwatch-ui]"
	@echo "    make port-forward-ec2                     # http://localhost:8080"
	@echo "    make port-forward-fargate                 # http://localhost:8081"
	@echo "    make port-forward-newrelic                # http://localhost:8082"
	@echo "    make port-forward-fargate-newrelic        # http://localhost:8083"
	@echo "    make compare-check                        # comparison guide"
	@echo "    make tf-apply                             # apply Terraform changes to existing infra"
	@echo "    make down                                 # destroy all resources"
	@echo ""

# ============================================================
# Common utilities
# ============================================================
check-prereq:
	@$(SCRIPTS_DIR)/check-prereq.sh

aws-whoami:
	@aws sts get-caller-identity

kube-context:
	@echo "==> Current context: $$(kubectl config current-context)"
	@echo ""
	@kubectl get nodes -o wide

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

create-secrets:
	@$(SCRIPTS_DIR)/create-secrets.sh

install-cloudwatch-full:
	@$(SCRIPTS_DIR)/install-cloudwatch-full.sh

install-newrelic-full:
	@$(SCRIPTS_DIR)/install-newrelic-full.sh

# ============================================================
# EKS on EC2 + App Signals  (namespace: eks-ec2-appsignals)
# ============================================================
ec2-appsignals-deploy:
	@$(SCRIPTS_DIR)/deploy-ec2.sh

ec2-appsignals-verify:
	@echo "==> EKS on EC2 + App Signals — Status"
	@echo ""
	@echo "--- Pods (eks-ec2-appsignals) ---"
	@kubectl get pods -n eks-ec2-appsignals -o wide
	@echo ""
	@echo "--- Services ---"
	@kubectl get svc -n eks-ec2-appsignals
	@echo ""
	@echo "--- CloudWatch Agent ---"
	@kubectl get pods -n amazon-cloudwatch 2>/dev/null || echo "  (amazon-cloudwatch namespace not found)"
	@echo ""
	@echo "--- OTel Operator ---"
	@kubectl get pods -n opentelemetry-operator-system 2>/dev/null || true
	@echo ""
	@echo "--- App Signals Console ---"
	@echo "  https://$(AWS_REGION).console.aws.amazon.com/cloudwatch/home?region=$(AWS_REGION)#application-signals:services"

ec2-appsignals-enable-rum:
	@$(SCRIPTS_DIR)/enable-rum.sh eks-ec2-appsignals

ec2-appsignals-enable-custom-metrics:
	@$(SCRIPTS_DIR)/enable-custom-metrics.sh

ec2-appsignals-down:
	@echo "==> Deleting eks-ec2-appsignals namespace..."
	@kubectl delete namespace eks-ec2-appsignals --timeout=120s 2>/dev/null || true
	@echo "Done."

# ============================================================
# EKS on Fargate + App Signals  (namespace: eks-fargate-appsignals)
# ============================================================
fargate-appsignals-deploy:
	@$(SCRIPTS_DIR)/deploy-fargate.sh

fargate-appsignals-verify:
	@echo "==> EKS on Fargate + App Signals — Status"
	@echo ""
	@echo "--- Pods (eks-fargate-appsignals) ---"
	@kubectl get pods -n eks-fargate-appsignals -o wide
	@echo ""
	@echo "--- Services ---"
	@kubectl get svc -n eks-fargate-appsignals

fargate-appsignals-enable-rum:
	@$(SCRIPTS_DIR)/enable-rum.sh eks-fargate-appsignals

fargate-appsignals-down:
	@echo "==> Deleting eks-fargate-appsignals namespace..."
	@kubectl delete namespace eks-fargate-appsignals --timeout=120s 2>/dev/null || true
	@echo "Done."

# ============================================================
# EKS on EC2 + New Relic  (namespace: eks-ec2-newrelic)
# ============================================================
ec2-newrelic-deploy:
	@$(SCRIPTS_DIR)/deploy-newrelic.sh

ec2-newrelic-verify:
	@echo "==> EKS on EC2 + New Relic — Status"
	@echo ""
	@echo "--- Pods (eks-ec2-newrelic) ---"
	@kubectl get pods -n eks-ec2-newrelic -o wide
	@echo ""
	@echo "--- New Relic Agent Injection ---"
	@kubectl get pods -n eks-ec2-newrelic -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.initContainers[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null || true
	@echo ""
	@echo "--- New Relic Infrastructure ---"
	@kubectl get pods -n newrelic 2>/dev/null || echo "  (newrelic namespace not found — run make install-newrelic-full)"

ec2-newrelic-down:
	@echo "==> Deleting eks-ec2-newrelic namespace..."
	@kubectl delete namespace eks-ec2-newrelic --timeout=120s 2>/dev/null || true
	@echo "Done."

# ============================================================
# EKS on Fargate + New Relic  (namespace: eks-fargate-newrelic)
# APM traces only — Infrastructure Agent (DaemonSet) not available on Fargate
# ============================================================
fargate-newrelic-deploy:
	@$(SCRIPTS_DIR)/deploy-fargate-newrelic.sh

fargate-newrelic-verify:
	@echo "==> EKS on Fargate + New Relic — Status (APM only)"
	@echo ""
	@echo "--- Pods (eks-fargate-newrelic) ---"
	@kubectl get pods -n eks-fargate-newrelic -o wide
	@echo ""
	@echo "--- New Relic Agent Injection ---"
	@kubectl get pods -n eks-fargate-newrelic -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.initContainers[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null || true
	@echo ""
	@echo "NOTE: Infrastructure Agent (DaemonSet) is not available on Fargate."
	@echo "      APM traces are collected. Infra metrics and NR Logs are not."

fargate-newrelic-down:
	@echo "==> Deleting eks-fargate-newrelic namespace..."
	@kubectl delete namespace eks-fargate-newrelic --timeout=120s 2>/dev/null || true
	@echo "Done."

# ============================================================
# Traffic generation
# ============================================================
load:
	@$(SCRIPTS_DIR)/load.sh all

load-normal:
	@$(SCRIPTS_DIR)/load.sh normal-dashboard

load-devices:
	@$(SCRIPTS_DIR)/load.sh normal-devices

load-detail:
	@$(SCRIPTS_DIR)/load.sh normal-device-detail

load-slow:
	@$(SCRIPTS_DIR)/load.sh slow-query-devices

load-error:
	@$(SCRIPTS_DIR)/load.sh error-inject-devices

load-storm:
	@$(SCRIPTS_DIR)/load.sh alert-storm-alerts

# ============================================================
# Utilities
# ============================================================
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

port-forward-fargate-newrelic:
	@$(SCRIPTS_DIR)/port-forward-fargate-newrelic.sh

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
	@echo "==> [3/5] Deleting Kubernetes namespaces (triggers ELB deletion)..."
	@kubectl delete namespace eks-ec2-appsignals     --timeout=30s 2>/dev/null || true
	@kubectl delete namespace eks-fargate-appsignals --timeout=30s 2>/dev/null || true
	@kubectl delete namespace eks-ec2-newrelic        --timeout=30s 2>/dev/null || true
	@kubectl delete namespace eks-fargate-newrelic    --timeout=30s 2>/dev/null || true
	@kubectl delete namespace newrelic                --timeout=30s 2>/dev/null || true
	@kubectl delete namespace aws-observability       --timeout=30s 2>/dev/null || true
	@echo "  Waiting for ELBs to be deregistered before VPC is deleted..."
	@for ns in eks-ec2-appsignals eks-fargate-appsignals eks-ec2-newrelic eks-fargate-newrelic; do \
		kubectl wait --for=delete namespace/$$ns --timeout=180s 2>/dev/null || true; \
	done

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
