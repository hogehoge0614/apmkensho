# ============================================================
# Observability PoC - Makefile
# CloudWatch + Application Signals vs New Relic Full Stack
# 3 environments: EC2+AppSignals, Fargate+AppSignals, EC2+NewRelic
# ============================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Load .env if present
-include .env
export

AWS_REGION    ?= ap-northeast-1
CLUSTER_NAME  ?= obs-poc
NS            ?= demo-ec2
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
        ec2-newrelic-deploy ec2-newrelic-verify ec2-newrelic-down \
        install-cloudwatch-full install-newrelic-full \
        load load-normal load-devices load-detail load-slow load-error load-storm \
        status logs compare-check \
        port-forward-ec2 port-forward-fargate port-forward-newrelic \
        deploy-ec2 deploy-fargate deploy-newrelic \
        down tf-init tf-plan tf-apply tf-destroy destroy-check

# ============================================================
# Help
# ============================================================
help:
	@echo ""
	@echo "  NetWatch Observability PoC"
	@echo "  AWS CloudWatch Application Signals  vs  New Relic Full Stack"
	@echo ""
	@echo "  Prerequisites: aws cli, kubectl, helm, docker, terraform"
	@echo "  Setup: cp .env.example .env && vi .env"
	@echo ""
	@echo "  ┌─────────────────────────────────────────────────────────────┐"
	@echo "  │  Quickstart — EC2 + App Signals (recommended start)         │"
	@echo "  │                                                             │"
	@echo "  │  1. make check-prereq             # verify tools & auth     │"
	@echo "  │  2. make up                       # create EKS + resources  │"
	@echo "  │  3. make create-secrets           # create K8s secrets      │"
	@echo "  │  4. make build-push               # build & push images     │"
	@echo "  │  5. make install-cloudwatch-full  # install CW stack        │"
	@echo "  │  6. make ec2-appsignals-deploy    # deploy apps             │"
	@echo "  │  7. make ec2-appsignals-verify    # check everything        │"
	@echo "  │  8. make load                     # generate traffic        │"
	@echo "  └─────────────────────────────────────────────────────────────┘"
	@echo ""
	@echo "  ── Environments ────────────────────────────────────────────────"
	@echo "    EC2 + App Signals:"
	@echo "      make ec2-appsignals-deploy          # deploy to demo-ec2"
	@echo "      make ec2-appsignals-enable-rum      # enable CW RUM browser monitoring"
	@echo "      make ec2-appsignals-enable-custom-metrics  # enable StatsD metrics"
	@echo "      make ec2-appsignals-verify          # verify pods/services"
	@echo "      make ec2-appsignals-down            # delete demo-ec2 namespace"
	@echo ""
	@echo "    Fargate + App Signals:"
	@echo "      make fargate-appsignals-deploy      # deploy to demo-fargate"
	@echo "      make fargate-appsignals-verify      # verify pods/services"
	@echo "      make fargate-appsignals-down        # delete demo-fargate namespace"
	@echo ""
	@echo "    EC2 + New Relic:"
	@echo "      make install-newrelic-full          # install NR stack (requires license key)"
	@echo "      make ec2-newrelic-deploy            # deploy to demo-newrelic"
	@echo "      make ec2-newrelic-verify            # verify pods/services"
	@echo "      make ec2-newrelic-down              # delete demo-newrelic namespace"
	@echo ""
	@echo "  ── Traffic Generation ──────────────────────────────────────────"
	@echo "    make load                   # all scenarios (default)"
	@echo "    make load-normal            # dashboard + device list"
	@echo "    make load-detail            # device detail pages (3-hop traces)"
	@echo "    make load-slow              # slow query scenario"
	@echo "    make load-error             # error injection scenario"
	@echo "    make load-storm             # alert storm scenario"
	@echo ""
	@echo "  ── Utilities ───────────────────────────────────────────────────"
	@echo "    make check-prereq           # verify tools & AWS auth"
	@echo "    make aws-whoami             # show current AWS identity"
	@echo "    make kube-context           # show current k8s context + nodes"
	@echo "    make status                 # cluster/pod/addon status"
	@echo "    make logs [NS=demo-ec2] [SVC=netwatch-ui]  # tail structured logs"
	@echo "    make port-forward-ec2       # http://localhost:8080"
	@echo "    make compare-check         # show observability comparison guide"
	@echo "    make down                   # destroy all resources"
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
# EC2 + App Signals
# ============================================================
ec2-appsignals-deploy:
	@$(SCRIPTS_DIR)/deploy-ec2.sh

ec2-appsignals-verify:
	@echo "==> EC2 + App Signals — Status"
	@echo ""
	@echo "--- Pods (demo-ec2) ---"
	@kubectl get pods -n demo-ec2 -o wide
	@echo ""
	@echo "--- Services ---"
	@kubectl get svc -n demo-ec2
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
	@$(SCRIPTS_DIR)/enable-rum.sh

ec2-appsignals-enable-custom-metrics:
	@$(SCRIPTS_DIR)/enable-custom-metrics.sh

ec2-appsignals-down:
	@echo "==> Deleting demo-ec2 namespace..."
	@kubectl delete namespace demo-ec2 --timeout=120s 2>/dev/null || true
	@echo "Done."

# ============================================================
# Fargate + App Signals
# ============================================================
fargate-appsignals-deploy:
	@$(SCRIPTS_DIR)/deploy-fargate.sh

fargate-appsignals-verify:
	@echo "==> Fargate + App Signals — Status"
	@echo ""
	@echo "--- Pods (demo-fargate) ---"
	@kubectl get pods -n demo-fargate -o wide
	@echo ""
	@echo "--- Services ---"
	@kubectl get svc -n demo-fargate

fargate-appsignals-down:
	@echo "==> Deleting demo-fargate namespace..."
	@kubectl delete namespace demo-fargate --timeout=120s 2>/dev/null || true
	@echo "Done."

# ============================================================
# EC2 + New Relic
# ============================================================
ec2-newrelic-deploy:
	@$(SCRIPTS_DIR)/deploy-newrelic.sh

ec2-newrelic-verify:
	@echo "==> EC2 + New Relic — Status"
	@echo ""
	@echo "--- Pods (demo-newrelic) ---"
	@kubectl get pods -n demo-newrelic -o wide
	@echo ""
	@echo "--- New Relic Agent Injection (look for newrelic-init) ---"
	@kubectl get pods -n demo-newrelic -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.initContainers[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null || true
	@echo ""
	@echo "--- New Relic Infrastructure ---"
	@kubectl get pods -n newrelic 2>/dev/null || echo "  (newrelic namespace not found — run make install-newrelic-full)"

ec2-newrelic-down:
	@echo "==> Deleting demo-newrelic namespace..."
	@kubectl delete namespace demo-newrelic --timeout=120s 2>/dev/null || true
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

# ============================================================
# Aliases (backward compat)
# ============================================================
deploy-ec2: ec2-appsignals-deploy
deploy-fargate: fargate-appsignals-deploy
deploy-newrelic: ec2-newrelic-deploy

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
	@kubectl delete namespace demo-ec2      --timeout=60s 2>/dev/null || true
	@kubectl delete namespace demo-fargate  --timeout=60s 2>/dev/null || true
	@kubectl delete namespace demo-newrelic --timeout=60s 2>/dev/null || true
	@kubectl delete namespace newrelic      --timeout=60s 2>/dev/null || true
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
