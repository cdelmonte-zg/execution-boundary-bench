.PHONY: help build push benchmark cold-start memory cpu concurrent clean setup-configmap lint

REGISTRY ?= ghcr.io/YOURUSERNAME
IMAGE    := $(REGISTRY)/bench-workload:latest
RUNS     ?= 100

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

# --- Build ---

build: ## Build workload image
	docker build -t $(IMAGE) workload/

push: build ## Build and push workload image
	docker push $(IMAGE)

update-manifests: ## Update REGISTRY in all manifests
	sed -i 's|REGISTRY/bench-workload:latest|$(IMAGE)|g' manifests/*.yaml

# --- Setup ---

setup-seccomp: ## Deploy seccomp profile to all nodes
	bash -c 'source cluster/setup-cluster.sh && deploy_seccomp'

setup-configmap: ## Create workload ConfigMap from server.py
	kubectl create configmap bench-workload \
		--from-file=server.py=workload/server.py \
		--dry-run=client -o yaml | kubectl apply -f -

# --- Benchmarks ---

benchmark: ## Run full benchmark suite (default: 100 runs)
	bash scripts/run-all.sh $(RUNS)

cold-start: ## Run cold-start benchmark for all runtimes
	bash scripts/cold-start.sh hardened $(RUNS)
	bash scripts/cold-start.sh kata $(RUNS)
	bash scripts/cold-start.sh kubevirt $(RUNS)

memory: ## Measure memory baseline (pods must be running)
	bash scripts/memory-baseline.sh hardened
	bash scripts/memory-baseline.sh kata
	bash scripts/memory-baseline.sh kubevirt

cpu: ## Measure CPU overhead (pods must be running)
	bash scripts/cpu-overhead.sh hardened
	bash scripts/cpu-overhead.sh kata
	bash scripts/cpu-overhead.sh kubevirt

concurrent: ## Find max concurrent sandboxes per node
	bash scripts/max-concurrent.sh hardened
	bash scripts/max-concurrent.sh kata

# --- Validation ---

lint: ## Run shellcheck on all scripts
	shellcheck scripts/*.sh cluster/*.sh

validate-manifests: ## Dry-run validate all manifests
	kubectl apply --dry-run=client -f manifests/hardened-container.yaml
	kubectl apply --dry-run=client -f manifests/kata-microvm.yaml
	kubectl apply --dry-run=client -f manifests/kubevirt-vm.yaml

# --- Cleanup ---

clean: ## Delete all benchmark pods/VMs
	kubectl delete pods -l app=bench --grace-period=0 --force 2>/dev/null || true
	kubectl delete pods -l app=bench-concurrent --grace-period=0 --force 2>/dev/null || true
	kubectl delete vm bench-kubevirt 2>/dev/null || true
	@echo "Cleaned."

clean-results: ## Delete all result files
	rm -f results/*.csv results/*.json
	@echo "Results cleaned."
