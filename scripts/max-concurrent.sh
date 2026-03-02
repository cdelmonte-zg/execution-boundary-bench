#!/usr/bin/env bash
#
# max-concurrent.sh — Find max concurrent sandboxes before saturation
#
# Usage: ./max-concurrent.sh <runtime>
#   runtime: hardened | kata
#
# Strategy: Linear ramp — deploy pods one at a time, verify readiness,
#           stop on OOM, Pending, CrashLoopBackOff, or node pressure.
#
# Output: results/max-concurrent-<runtime>.json

set -euo pipefail

RUNTIME="${1:?Usage: $0 <hardened|kata>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
OUTFILE="${RESULTS_DIR}/max-concurrent-${RUNTIME}.json"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

mkdir -p "$RESULTS_DIR"

# shellcheck source=lib-env.sh
source "${SCRIPT_DIR}/lib-env.sh"
capture_environment

# Map runtime to manifest
case "$RUNTIME" in
  hardened)
    BASE_MANIFEST="${MANIFEST_DIR}/hardened-container.yaml"
    ;;
  kata)
    BASE_MANIFEST="${MANIFEST_DIR}/kata-microvm.yaml"
    ;;
  *)
    echo "Unsupported runtime for concurrent test: $RUNTIME (only hardened|kata)" >&2
    exit 1
    ;;
esac

MAX_ATTEMPTS=200
READY_TIMEOUT=120
COUNT=0

# Pin all pods to a single worker node (first non-control-plane node)
# This measures per-node density, not cluster-wide capacity.
TARGET_NODE=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$TARGET_NODE" ]]; then
  # Fallback: use any node
  TARGET_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

# --- Cleanup function ---
cleanup_concurrent() {
  echo "  Cleaning up concurrent pods..."
  kubectl delete pods -l app=bench-concurrent --grace-period=0 --force 2>/dev/null || true
  # Wait for actual removal
  local retries=0
  while kubectl get pods -l app=bench-concurrent --no-headers 2>/dev/null | grep -q .; do
    sleep 1
    retries=$((retries + 1))
    if [[ "$retries" -gt 60 ]]; then
      echo "  WARNING: Cleanup timed out after 60s"
      break
    fi
  done
}

# --- Node pressure check ---
check_node_pressure() {
  local conditions
  conditions=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="MemoryPressure")].status}{" "}{.status.conditions[?(@.type=="DiskPressure")].status}{"\n"}{end}' 2>/dev/null)
  echo "$conditions" | grep -q "True" && return 0
  return 1
}

# Cleanup on interrupt
trap 'echo ""; echo "  Interrupted — cleaning up..."; cleanup_concurrent; exit 130' INT TERM

# Ensure clean state
cleanup_concurrent

echo "=== Max Concurrent Benchmark: ${RUNTIME} ==="
echo "  Target node: ${TARGET_NODE}"
echo "  Scaling pods until saturation (max ${MAX_ATTEMPTS})..."
echo ""

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  POD_NAME="bench-concurrent-${RUNTIME}-${i}"

  # Generate pod with unique name, concurrent label, and pinned to target node
  sed \
    -e "s/name: bench-${RUNTIME}/name: ${POD_NAME}/" \
    -e "s/app: bench$/app: bench-concurrent/" \
    -e "/^spec:/a\\  nodeName: ${TARGET_NODE}" \
    "$BASE_MANIFEST" | kubectl apply -f - > /dev/null 2>&1

  # Wait for pod to become Ready or fail
  if ! kubectl wait --for=condition=Ready "pod/${POD_NAME}" --timeout="${READY_TIMEOUT}s" 2>/dev/null; then
    # Pod failed to become ready — determine why
    POD_STATUS=$(kubectl get pod "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    REASON=$(kubectl get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")

    echo "    [${i}] FAILED — phase=${POD_STATUS} reason=${REASON}"
    kubectl delete pod "$POD_NAME" --grace-period=0 --force 2>/dev/null || true
    break
  fi

  # Check node pressure after successful scheduling
  if check_node_pressure; then
    echo "    [${i}] Node pressure detected — stopping"
    break
  fi

  COUNT=$i
  printf "    [%3d] %s — Ready\n" "$i" "$POD_NAME"
done

echo ""
echo "  Max concurrent stable: ${COUNT}"

cat <<EOF > "$OUTFILE"
{
  "runtime": "${RUNTIME}",
  "max_concurrent_stable": ${COUNT},
  "target_node": "${TARGET_NODE}",
  "cpu_limit_per_pod": "100m",
  "memory_limit_per_pod": "128Mi",
$(platform_json),
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

echo "  Written to: ${OUTFILE}"

# Cleanup
cleanup_concurrent
