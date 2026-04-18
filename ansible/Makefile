# Makefile for ClusterForge Ansible Bootstrap
.PHONY: help install check bootstrap clean

# Default domain (override with make bootstrap DOMAIN=your-domain.com)
DOMAIN ?= example.com
CLUSTER_SIZE ?= medium
TARGET_REVISION ?= v2.0.4

help: ## Show this help message
	@echo "ClusterForge Ansible Bootstrap - Makefile"
	@echo ""
	@echo "Usage:"
	@echo "  make install          - Install Ansible and required collections"
	@echo "  make check            - Verify all dependencies are installed"
	@echo "  make bootstrap        - Run bootstrap (set DOMAIN=your-domain.com)"
	@echo "  make clean            - Clean up temporary files"
	@echo ""
	@echo "Examples:"
	@echo "  make bootstrap DOMAIN=example.com"
	@echo "  make bootstrap DOMAIN=example.com CLUSTER_SIZE=large"
	@echo "  make bootstrap DOMAIN=192.168.1.100.nip.io TARGET_REVISION=v2.0.3"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

install: ## Install Ansible and required collections
	@echo "Installing Ansible collections..."
	ansible-galaxy collection install -r requirements.yml
	@echo "✅ Collections installed successfully"

check: ## Check for required dependencies
	@echo "Checking dependencies..."
	@command -v ansible >/dev/null 2>&1 || { echo "❌ ansible not found. Install with: sudo apt install ansible"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not found"; exit 1; }
	@command -v helm >/dev/null 2>&1 || { echo "❌ helm not found"; exit 1; }
	@command -v yq >/dev/null 2>&1 || { echo "❌ yq not found"; exit 1; }
	@command -v openssl >/dev/null 2>&1 || { echo "❌ openssl not found"; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo "❌ git not found"; exit 1; }
	@echo "✅ All dependencies found"
	@echo ""
	@ansible --version | head -n1
	@echo "kubectl: $$(kubectl version --client --short 2>/dev/null || echo 'version check failed')"
	@echo "helm: $$(helm version --short 2>/dev/null || echo 'version check failed')"
	@echo "yq: $$(yq --version 2>/dev/null || echo 'version check failed')"

bootstrap: check ## Run the bootstrap playbook
	@if [ "$(DOMAIN)" = "example.com" ]; then \
		echo "⚠️  Using default domain 'example.com'"; \
		echo "   Set a real domain with: make bootstrap DOMAIN=your-domain.com"; \
		echo ""; \
	fi
	@echo "Running bootstrap with:"
	@echo "  Domain: $(DOMAIN)"
	@echo "  Cluster Size: $(CLUSTER_SIZE)"
	@echo "  Target Revision: $(TARGET_REVISION)"
	@echo ""
	ansible-playbook bootstrap.yml \
		-e cluster_domain=$(DOMAIN) \
		-e cluster_size=$(CLUSTER_SIZE) \
		-e cluster_forge_target_revision=$(TARGET_REVISION)

bootstrap-small: ## Bootstrap a small cluster
	@$(MAKE) bootstrap CLUSTER_SIZE=small

bootstrap-large: ## Bootstrap a large cluster
	@$(MAKE) bootstrap CLUSTER_SIZE=large

bootstrap-aiwb: ## Bootstrap AIWB-only cluster
	@echo "Running AIWB-only bootstrap..."
	ansible-playbook bootstrap.yml \
		-e cluster_domain=$(DOMAIN) \
		-e cluster_size=$(CLUSTER_SIZE) \
		-e aiwb_only=true

clean: ## Clean up temporary files and caches
	@echo "Cleaning up..."
	rm -rf /tmp/ansible_facts
	rm -rf .ansible
	rm -f *.retry
	@echo "✅ Cleanup complete"

verify: ## Verify cluster after bootstrap
	@echo "Verifying cluster..."
	@echo ""
	@echo "Namespaces:"
	@kubectl get namespaces | grep -E "(argocd|cf-gitea|cf-openbao)" || echo "⚠️  Expected namespaces not found"
	@echo ""
	@echo "ArgoCD Applications:"
	@kubectl get applications -n argocd 2>/dev/null || echo "⚠️  No applications found"
	@echo ""
	@echo "Pods Status:"
	@kubectl get pods -n argocd
	@kubectl get pods -n cf-gitea
	@kubectl get pods -n cf-openbao
