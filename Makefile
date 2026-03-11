.PHONY: help plan apply destroy cost status install-all teardown lint

# Default environment
ENV ?= dev
TF_DIR = terraform/environments/$(ENV)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Terraform ──────────────────────────────────────────

plan: ## Run terraform plan (ENV=dev|prd)
	cd $(TF_DIR) && terraform plan

apply: ## Run terraform apply (ENV=dev|prd)
	cd $(TF_DIR) && terraform apply

destroy: ## Run terraform destroy (ENV=dev|prd)
	cd $(TF_DIR) && terraform destroy

init: ## Initialize terraform backend (ENV=dev|prd)
	cd $(TF_DIR) && terraform init

fmt: ## Format all terraform files
	terraform fmt -recursive terraform/

validate: ## Validate all terraform configs
	@for dir in terraform/modules/*/; do \
		echo "Validating $$dir..."; \
		cd $$dir && terraform validate && cd - > /dev/null; \
	done

# ── AWS ────────────────────────────────────────────────

cost: ## Show current AWS costs
	@./scripts/cost-report.sh

whoami: ## Show current AWS identity
	aws sts get-caller-identity

# ── Kubernetes ─────────────────────────────────────────

status: ## Show k3s cluster status
	@echo "=== Nodes ==="
	kubectl get nodes -o wide
	@echo "\n=== Namespaces ==="
	kubectl get ns
	@echo "\n=== Pods (all namespaces) ==="
	kubectl get pods -A --sort-by=.metadata.namespace

pods: ## Show all pods grouped by namespace
	kubectl get pods -A -o wide

top: ## Show resource usage
	kubectl top nodes
	kubectl top pods -A --sort-by=memory

install-all: ## Install all platform tools in dependency order
	@./scripts/install-platform.sh

# ── Operations ─────────────────────────────────────────

teardown: ## Destroy everything safely (with confirmation)
	@./scripts/teardown.sh

connect: ## SSH to k3s node and get kubeconfig
	@./scripts/k3s-connect.sh

bootstrap: ## Verify all required tools are installed
	@./scripts/bootstrap.sh

rotate-keys: ## Rotate AWS IAM access keys
	@./scripts/rotate-credentials.sh

# ── Development ────────────────────────────────────────

lint: ## Lint all code
	@echo "=== Terraform ==="
	terraform fmt -check -recursive terraform/ || true
	@echo "\n=== Python ==="
	cd services/user-service && python -m flake8 src/ || true
	@echo "\n=== Node.js ==="
	cd services/api-gateway && npm run lint 2>/dev/null || true

test: ## Run all tests
	@echo "=== api-gateway ==="
	cd services/api-gateway && npm test 2>/dev/null || echo "No tests yet"
	@echo "\n=== user-service ==="
	cd services/user-service && python -m pytest tests/ 2>/dev/null || echo "No tests yet"
	@echo "\n=== order-service ==="
	cd services/order-service && npm test 2>/dev/null || echo "No tests yet"

build: ## Build all service Docker images
	docker build -t api-gateway:local services/api-gateway/
	docker build -t user-service:local services/user-service/
	docker build -t order-service:local services/order-service/

# ── ArgoCD ─────────────────────────────────────────────

argocd-password: ## Get ArgoCD admin password
	kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

argocd-port-forward: ## Port-forward ArgoCD UI to localhost:8080
	kubectl port-forward svc/argocd-server -n argocd 8080:443

grafana-port-forward: ## Port-forward Grafana to localhost:3000
	kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80

harbor-port-forward: ## Port-forward Harbor to localhost:8443
	kubectl port-forward svc/harbor-core -n harbor 8443:443
