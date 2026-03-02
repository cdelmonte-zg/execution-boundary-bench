#!/usr/bin/env bash
#
# lib-env.sh — Capture platform environment for benchmark results
#
# Source this file to get ENV_* variables and platform_json() function.
# All data comes from the Kubernetes API (no pod spawning, fast).

# Guard against double-sourcing
[[ -n "${_LIB_ENV_LOADED:-}" ]] && return 0
_LIB_ENV_LOADED=1

capture_environment() {
  local first_node
  first_node=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  ENV_K8S_VERSION=$(kubectl version -o json 2>/dev/null | \
    python3 -c "import sys,json; sv=json.load(sys.stdin).get('serverVersion',{}); print(sv.get('gitVersion','unknown'))" \
    2>/dev/null || echo "unknown")

  ENV_NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ENV_NODE_CPU=$(kubectl get node "$first_node" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null || echo "unknown")

  local ram_ki
  ram_ki=$(kubectl get node "$first_node" -o jsonpath='{.status.capacity.memory}' 2>/dev/null || echo "0Ki")
  ENV_NODE_RAM_GB=$(echo "$ram_ki" | sed 's/Ki//' | awk '{printf "%.0f", $1 / 1048576}')

  ENV_KERNEL=$(kubectl get node "$first_node" -o jsonpath='{.status.nodeInfo.kernelVersion}' 2>/dev/null || echo "unknown")
  ENV_OS_IMAGE=$(kubectl get node "$first_node" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null || echo "unknown")
  ENV_CONTAINER_RUNTIME=$(kubectl get node "$first_node" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || echo "unknown")
}

# Emit a JSON fragment (no surrounding braces) for embedding in result files.
# Usage: platform_json >> "$OUTFILE"  (inside a heredoc or jq merge)
platform_json() {
  cat <<ENVJSON
  "platform": {
    "kubernetes": "${ENV_K8S_VERSION}",
    "nodes": "${ENV_NODE_COUNT} x ${ENV_NODE_CPU} vCPU, ${ENV_NODE_RAM_GB} GB RAM",
    "kernel": "${ENV_KERNEL}",
    "os": "${ENV_OS_IMAGE}",
    "container_runtime": "${ENV_CONTAINER_RUNTIME}"
  }
ENVJSON
}
