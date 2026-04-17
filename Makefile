# Makefile — vault-secrets-manager project automation
# Provides targets for the full Vault lifecycle: deploy, initialize,
# provision, validate, test, and secret rotation.

.PHONY: help up down init-vault provision validate test rotate \
        lint shellcheck yaml-lint policy-check clean logs status

# ─── Configuration ────────────────────────────────────────────────────────────
SHELL := /bin/bash
.DEFAULT_GOAL := help

DOCKER_COMPOSE := docker compose -f docker/docker-compose.yml
TERRAFORM_DIR  := terraform
VAULT_ADDR     ?= http://127.0.0.1:8200
VAULT_TOKEN    ?=
KV_MOUNT       ?= secret

# Colors for terminal output
CYAN  := \033[0;36m
GREEN := \033[0;32m
YELLOW := \033[1;33m
NC    := \033[0m

# ─── Help ─────────────────────────────────────────────────────────────────────
help: ## Show this help message
	@echo ""
	@echo "$(CYAN)vault-secrets-manager$(NC) — HashiCorp Vault deployment & management"
	@echo ""
	@echo "$(GREEN)Lifecycle targets:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-18s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Quick start:$(NC)"
	@echo "  make up            # Start Vault + Consul containers"
	@echo "  make init-vault    # Initialize and unseal Vault"
	@echo "  make provision     # Apply Terraform configuration"
	@echo "  make test          # Run integration tests"
	@echo ""

# ─── Lifecycle Targets ────────────────────────────────────────────────────────

up: ## Start Vault and Consul containers via Docker Compose
	@echo -e "$(CYAN)[MAKE]$(NC) Starting Vault and Consul..."
	$(DOCKER_COMPOSE) up -d
	@echo -e "$(GREEN)[MAKE]$(NC) Waiting for Vault to be ready..."
	@for i in $$(seq 1 30); do \
		if curl -s $(VAULT_ADDR)/v1/sys/health > /dev/null 2>&1; then \
			echo -e "$(GREEN)[MAKE]$(NC) Vault is ready at $(VAULT_ADDR)"; \
			break; \
		fi; \
		sleep 1; \
	done
	@echo -e "$(GREEN)[MAKE]$(NC) Vault UI available at $(VAULT_ADDR)/ui"

down: ## Stop and remove Vault and Consul containers
	@echo -e "$(CYAN)[MAKE]$(NC) Stopping containers..."
	$(DOCKER_COMPOSE) down -v
	@echo -e "$(GREEN)[MAKE]$(NC) Containers stopped and volumes removed"

init-vault: ## Initialize Vault, unseal, and seed example secrets
	@echo -e "$(CYAN)[MAKE]$(NC) Initializing Vault..."
	@chmod +x scripts/init-vault.sh scripts/seed-secrets.sh
	@bash scripts/init-vault.sh
	@echo -e "$(CYAN)[MAKE]$(NC) Seeding example secrets..."
	@bash scripts/seed-secrets.sh
	@echo -e "$(GREEN)[MAKE]$(NC) Vault initialized and seeded"

provision: ## Apply Terraform configuration to provision Vault resources
	@echo -e "$(CYAN)[MAKE]$(NC) Provisioning Vault via Terraform..."
	@cd $(TERRAFORM_DIR) && terraform init -input=false
	@cd $(TERRAFORM_DIR) && terraform plan -out=tfplan
	@cd $(TERRAFORM_DIR) && terraform apply -auto-approve tfplan
	@rm -f $(TERRAFORM_DIR)/tfplan
	@echo -e "$(GREEN)[MAKE]$(NC) Vault provisioning complete"

validate: lint shellcheck yaml-lint policy-check ## Run all validation checks
	@echo -e "$(GREEN)[MAKE]$(NC) All validation checks passed"

test: ## Run integration tests against a running Vault instance
	@echo -e "$(CYAN)[MAKE]$(NC) Running integration tests..."
	@chmod +x tests/test-vault-setup.sh
	@bash tests/test-vault-setup.sh
	@echo -e "$(GREEN)[MAKE]$(NC) Integration tests complete"

rotate: ## Rotate application secrets in Vault
	@echo -e "$(CYAN)[MAKE]$(NC) Rotating secrets..."
	@chmod +x scripts/rotate-secrets.sh
	@bash scripts/rotate-secrets.sh
	@echo -e "$(GREEN)[MAKE]$(NC) Secret rotation complete"

# ─── Validation Targets ──────────────────────────────────────────────────────

lint: ## Validate Terraform configuration format and syntax
	@echo -e "$(CYAN)[MAKE]$(NC) Checking Terraform formatting..."
	@terraform fmt -check -recursive -diff $(TERRAFORM_DIR)/
	@echo -e "$(CYAN)[MAKE]$(NC) Validating Terraform configuration..."
	@cd $(TERRAFORM_DIR) && terraform init -backend=false -input=false > /dev/null 2>&1
	@cd $(TERRAFORM_DIR) && terraform validate
	@echo -e "$(GREEN)[MAKE]$(NC) Terraform validation passed"

shellcheck: ## Lint all shell scripts with ShellCheck
	@echo -e "$(CYAN)[MAKE]$(NC) Running ShellCheck..."
	@find . -name "*.sh" -type f -exec shellcheck -x -S warning {} +
	@echo -e "$(GREEN)[MAKE]$(NC) ShellCheck passed"

yaml-lint: ## Lint YAML files (K8s manifests, Docker Compose, workflows)
	@echo -e "$(CYAN)[MAKE]$(NC) Linting YAML files..."
	@if command -v yamllint > /dev/null 2>&1; then \
		yamllint k8s/ docker/docker-compose.yml .github/workflows/ 2>/dev/null || true; \
		echo -e "$(GREEN)[MAKE]$(NC) YAML lint complete"; \
	else \
		echo -e "$(YELLOW)[MAKE]$(NC) yamllint not installed, skipping (pip install yamllint)"; \
	fi

policy-check: ## Validate Vault HCL policy syntax
	@echo -e "$(CYAN)[MAKE]$(NC) Validating Vault policies..."
	@chmod +x scripts/validate-policies.sh
	@bash scripts/validate-policies.sh
	@echo -e "$(GREEN)[MAKE]$(NC) Policy validation passed"

# ─── Utility Targets ─────────────────────────────────────────────────────────

status: ## Show Vault server status and seal state
	@echo -e "$(CYAN)[MAKE]$(NC) Vault status:"
	@curl -s $(VAULT_ADDR)/v1/sys/health | python3 -m json.tool 2>/dev/null || \
		echo -e "$(YELLOW)[MAKE]$(NC) Vault is not reachable at $(VAULT_ADDR)"
	@echo ""
	@echo -e "$(CYAN)[MAKE]$(NC) Container status:"
	@$(DOCKER_COMPOSE) ps 2>/dev/null || true

logs: ## Tail Vault and Consul container logs
	$(DOCKER_COMPOSE) logs -f --tail=50

clean: ## Remove generated files and Terraform state
	@echo -e "$(CYAN)[MAKE]$(NC) Cleaning up..."
	@rm -rf $(TERRAFORM_DIR)/.terraform
	@rm -f $(TERRAFORM_DIR)/.terraform.lock.hcl
	@rm -f $(TERRAFORM_DIR)/tfplan
	@rm -f $(TERRAFORM_DIR)/terraform.tfstate*
	@echo -e "$(GREEN)[MAKE]$(NC) Clean complete"
