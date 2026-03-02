#!/usr/bin/env bash
#
# cold-start.sh — Measure cold start latency per runtime
#
# Usage: ./cold-start.sh <runtime> [runs]
#   runtime: hardened | kata | kubevirt
#   runs:    number of iterations (default: 100)
#
# Output: results/cold-start-<runtime>.csv
#
# Definition: T0 = kubectl apply accepted, T1 = readiness probe OK
# No image caching: each run deletes the pod and waits for full cleanup.

set -euo pipefail

RUNTIME="${1:?Usage: $0 <hardened|kata|kubevirt> [runs]}"
RUNS="${2:-100}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
OUTFILE="${RESULTS_DIR}/cold-start-${RUNTIME}.csv"
SUMMARY_FILE="${RESULTS_DIR}/cold-start-${RUNTIME}.json"

mkdir -p "$RESULTS_DIR"

# shellcheck source=lib-env.sh
source "${SCRIPT_DIR}/lib-env.sh"
capture_environment

# Map runtime to manifest and pod/vm name
case "$RUNTIME" in
  hardened)
    MANIFEST="${SCRIPT_DIR}/../manifests/hardened-container.yaml"
    POD_NAME="bench-hardened"
    RESOURCE_TYPE="pod"
    ;;
  kata)
    MANIFEST="${SCRIPT_DIR}/../manifests/kata-microvm.yaml"
    POD_NAME="bench-kata"
    RESOURCE_TYPE="pod"
    ;;
  kubevirt)
    MANIFEST="${SCRIPT_DIR}/../manifests/kubevirt-vm.yaml"
    POD_NAME="bench-kubevirt"
    RESOURCE_TYPE="vm"
    ;;
  *)
    echo "Unknown runtime: $RUNTIME" >&2
    exit 1
    ;;
esac

# For cold start we lift CPU limits so we measure boot latency, not CFS throttling.
# The steady-state manifests (100m) are used for memory/CPU baseline measurements.
# We patch CPU limits to 1000m (1 core) during cold start.
COLD_START_CPU="1000m"

echo "run,runtime,cold_start_ms" > "$OUTFILE"

# Cleanup on interrupt (Ctrl+C)
trap 'echo ""; echo "  Interrupted — cleaning up..."; cleanup "$POD_NAME" "$RESOURCE_TYPE"; exit 130' INT TERM

wait_for_ready() {
  local name="$1"
  local resource_type="$2"
  local timeout=120

  if [[ "$resource_type" == "pod" ]]; then
    kubectl wait --for=condition=Ready "pod/${name}" --timeout="${timeout}s" 2>/dev/null
  else
    # KubeVirt: VMI Ready condition is set when the readinessProbe (HTTP /ready:8080)
    # succeeds. So kubectl wait here measures the full cold start including app readiness.
    kubectl wait --for=condition=Ready "vmi/${name}" --timeout=300s 2>/dev/null
  fi
}

cleanup() {
  local name="$1"
  local resource_type="$2"

  local wait_retries=0
  if [[ "$resource_type" == "pod" ]]; then
    kubectl delete pod "$name" --ignore-not-found --grace-period=0 --force 2>/dev/null || true
    while kubectl get pod "$name" &>/dev/null; do
      sleep 0.5
      wait_retries=$((wait_retries + 1))
      if [[ "$wait_retries" -ge 120 ]]; then
        echo "  WARNING: Cleanup timed out for pod ${name}" >&2
        break
      fi
    done
  else
    kubectl delete vm "$name" --ignore-not-found --grace-period=0 2>/dev/null || true
    while kubectl get vmi "$name" &>/dev/null; do
      sleep 1
      wait_retries=$((wait_retries + 1))
      if [[ "$wait_retries" -ge 120 ]]; then
        echo "  WARNING: Cleanup timed out for vmi ${name}" >&2
        break
      fi
    done
  fi
  # Brief pause to ensure node resources are released
  sleep 2
}

echo "=== Cold Start Benchmark: ${RUNTIME} (${RUNS} runs) ==="
echo ""

# --- Image warmup: ensure images are cached before timed runs ---
# On a fresh cluster, the first run includes image pull latency (~5-10s for
# python:3.11-slim). This warmup run pulls images without counting toward
# the benchmark, so all timed runs measure pure runtime overhead.
echo "  Warmup: pre-pulling images..."
cleanup "$POD_NAME" "$RESOURCE_TYPE"

if [[ "$RESOURCE_TYPE" == "pod" ]]; then
  sed "s/cpu: 100m/cpu: ${COLD_START_CPU}/g" "$MANIFEST" | kubectl apply -f - > /dev/null
else
  kubectl apply -f "$MANIFEST" > /dev/null
fi

if wait_for_ready "$POD_NAME" "$RESOURCE_TYPE"; then
  echo "  Warmup complete — images cached"
else
  echo "  Warmup timed out — proceeding anyway"
fi
cleanup "$POD_NAME" "$RESOURCE_TYPE"
echo ""

for i in $(seq 1 "$RUNS"); do
  # Ensure clean state
  cleanup "$POD_NAME" "$RESOURCE_TYPE"

  # T0: apply (with CPU limit lifted to avoid CFS throttling during boot)
  T0=$(date +%s%N)

  if [[ "$RESOURCE_TYPE" == "pod" ]]; then
    # Patch CPU limits inline so cold start measures boot latency, not throttling
    sed "s/cpu: 100m/cpu: ${COLD_START_CPU}/g" "$MANIFEST" | kubectl apply -f - > /dev/null
  else
    # KubeVirt VM — apply as-is (VM CPU is managed by QEMU, not CFS)
    kubectl apply -f "$MANIFEST" > /dev/null
  fi

  # T1: ready
  if wait_for_ready "$POD_NAME" "$RESOURCE_TYPE"; then
    T1=$(date +%s%N)
    ELAPSED_MS=$(( (T1 - T0) / 1000000 ))
    echo "${i},${RUNTIME},${ELAPSED_MS}" >> "$OUTFILE"
    printf "  [%3d/%d] %s: %d ms\n" "$i" "$RUNS" "$RUNTIME" "$ELAPSED_MS"
  else
    echo "${i},${RUNTIME},TIMEOUT" >> "$OUTFILE"
    printf "  [%3d/%d] %s: TIMEOUT\n" "$i" "$RUNS" "$RUNTIME"
  fi

  # Cleanup for next run
  cleanup "$POD_NAME" "$RESOURCE_TYPE"
done

echo ""
echo "Results written to: ${OUTFILE}"

# Compute summary stats
echo ""
echo "=== Summary ==="

STATS=$(awk -F',' '
  NR > 1 && $3 != "TIMEOUT" {
    values[NR] = $3
    sum += $3
    n++
    timeouts = 0
  }
  NR > 1 && $3 == "TIMEOUT" { timeouts++ }
  END {
    if (n == 0) { printf "0 0 0 0 0"; exit }
    asort(values)
    p50 = values[int(n * 0.50)]
    p95 = values[int(n * 0.95)]
    mean = sum / n
    printf "%d %d %d %d %d", n, p50, p95, mean, timeouts+0
  }
' "$OUTFILE")

read -r STAT_RUNS STAT_P50 STAT_P95 STAT_MEAN STAT_TIMEOUTS <<< "$STATS"

if [[ "$STAT_RUNS" -eq 0 ]]; then
  echo "  No successful runs"
else
  printf "  Runs:     %d\n" "$STAT_RUNS"
  printf "  Timeouts: %d\n" "$STAT_TIMEOUTS"
  printf "  P50:      %d ms\n" "$STAT_P50"
  printf "  P95:      %d ms\n" "$STAT_P95"
  printf "  Mean:     %d ms\n" "$STAT_MEAN"
fi

# Write JSON summary with platform info
cat <<EOF > "$SUMMARY_FILE"
{
  "runtime": "${RUNTIME}",
  "runs": ${STAT_RUNS},
  "timeouts": ${STAT_TIMEOUTS},
  "p50_ms": ${STAT_P50},
  "p95_ms": ${STAT_P95},
  "mean_ms": ${STAT_MEAN},
  "cold_start_cpu_limit": "${COLD_START_CPU}",
  "image_pull_policy": "IfNotPresent",
  "conditions": "images pre-pulled via warmup run, cluster idle, no concurrent workloads",
$(platform_json),
  "csv_file": "cold-start-${RUNTIME}.csv",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

echo "  Written to: ${SUMMARY_FILE}"
