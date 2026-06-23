# Flux operations for the mochi cluster.
# Requires the `flux` CLI with a kubeconfig pointing at the cluster.

.DEFAULT_GOAL := help

# ImageUpdateAutomation + GitRepository + ImageUpdateAutomation all live here.
FLUX_NS    ?= flux-system
GIT_SOURCE ?= flux-system
IMAGE_AUTO ?= flux-system

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

.PHONY: sync
sync: source reconcile ## Pull latest git + reconcile all kustomizations

.PHONY: source
source: ## Fetch the latest commit from git
	flux reconcile source git $(GIT_SOURCE)

.PHONY: reconcile
reconcile: ## Reconcile every kustomization against the current revision
	flux reconcile kustomization --all 2>/dev/null \
		|| for k in $$(flux get kustomizations --no-header | awk '{print $$1}'); do \
			flux reconcile kustomization $$k; \
		done

.PHONY: scan
scan: ## Re-scan image repositories for new tags
	for r in $$(flux get image repository --no-header | awk '{print $$1}'); do \
		flux reconcile image repository $$r; \
	done

.PHONY: update
update: scan ## Scan images and run the image-update automation (writes image bumps to git)
	flux reconcile image update $(IMAGE_AUTO)

.PHONY: status
status: ## Show kustomization, source, and image policy status
	@echo "== kustomizations =="; flux get kustomizations
	@echo "\n== sources =="; flux get sources git
	@echo "\n== image policies =="; flux get image policy

.PHONY: restart-shopmon
restart-shopmon: ## Restart shopmon api pods (picks up ConfigMap env changes)
	kubectl rollout restart deployment/api -n shopmon-prod
	kubectl rollout restart deployment/api -n shopmon-staging
	kubectl rollout status deployment/api -n shopmon-prod
	kubectl rollout status deployment/api -n shopmon-staging
