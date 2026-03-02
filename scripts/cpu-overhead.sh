#!/usr/bin/env bash
#
# cpu-overhead.sh — Measure idle CPU overhead per runtime
#
# Usage: ./cpu-overhead.sh <runtime>
#   runtime: hardened | kata | kubevirt
#
# Requires: pod/VM already running and idle.
# Output: results/cpu-<runtime>.json
#
# Methodology:
#   6 samples at 10-second intervals = 60 seconds total.
#   hardened/kubevirt: kubectl top (cgroup CPU from metrics-server)
#   kata: privileged probe to read host-side process CPU
#   Expressed as millicores and as percentage of the 100m CPU limit.

set -euo pipefail

RUNTIME="${1:?Usage: $0 <hardened|kata|kubevirt>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
OUTFILE="${RESULTS_DIR}/cpu-${RUNTIME}.json"

SAMPLES=6
INTERVAL=10  # 6 × 10s = 60s
CPU_LIMIT_MILLICORES=100

mkdir -p "$RESULTS_DIR"

# shellcheck source=lib-env.sh
source "${SCRIPT_DIR}/lib-env.sh"
capture_environment

POD_NAME="bench-${RUNTIME}"

# Resolve which pod to measure (for hardened/kubevirt)
resolve_target() {
  local runtime="$1"
  case "$runtime" in
    hardened|kata)
      echo "$POD_NAME"
      ;;
    kubevirt)
      kubectl get pods -l "vm.kubevirt.io/name=${POD_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
      ;;
  esac
}

TARGET_POD=$(resolve_target "$RUNTIME")
if [[ -z "$TARGET_POD" ]]; then
  echo "ERROR: Cannot resolve target pod for ${RUNTIME}" >&2
  exit 1
fi

NODE=$(kubectl get pod "$TARGET_POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
if [[ -z "$NODE" ]]; then
  echo "ERROR: Cannot determine node for pod ${TARGET_POD}" >&2
  exit 1
fi

# Wait for pod to settle before measuring idle CPU
echo "  Waiting 30s for CPU to settle..."
sleep 30

echo "  Sampling idle CPU over 60s (${SAMPLES} samples, ${INTERVAL}s interval)..."
echo "  Target pod: ${TARGET_POD} (node: ${NODE})"

# Get CPU millicores via kubectl top (works for hardened and kubevirt)
get_cpu_kubectl_top() {
  local pod="$1"
  local raw
  raw=$(kubectl top pod "$pod" --no-headers 2>/dev/null | awk '{print $2}')
  # kubectl top returns "2m" or "0m" — strip suffix
  echo "$raw" | sed 's/[^0-9.]//g'
}

# Get CPU for Kata from host-side process stats (jiffies delta approach)
# Since host-side CPU is complex to measure per-sample, we use kubectl top
# which reports container-level CPU (what the cgroup sees). For Kata, this
# captures the VM-level CPU but not the shim/QEMU overhead on the host.
# We note this limitation in the output.
get_cpu_millicores() {
  local runtime="$1"
  local pod="$2"
  case "$runtime" in
    hardened|kubevirt)
      get_cpu_kubectl_top "$pod"
      ;;
    kata)
      # kubectl top for Kata reports guest-side CPU only
      get_cpu_kubectl_top "$pod"
      ;;
  esac
}

CPU_SUM=0
VALID_SAMPLES=0

for i in $(seq 1 "$SAMPLES"); do
  sleep "$INTERVAL"

  MILLICORES=$(get_cpu_millicores "$RUNTIME" "$TARGET_POD")

  if [[ -z "$MILLICORES" ]]; then
    printf "    Sample %d/%d: UNAVAILABLE\n" "$i" "$SAMPLES"
    continue
  fi

  CPU_PCT=$(echo "$MILLICORES $CPU_LIMIT_MILLICORES" | awk '{printf "%.2f", ($1 / $2) * 100}')

  printf "    Sample %d/%d: %sm (%s%% of %dm limit)\n" "$i" "$SAMPLES" "$MILLICORES" "$CPU_PCT" "$CPU_LIMIT_MILLICORES"

  CPU_SUM=$(echo "$CPU_SUM $MILLICORES" | awk '{printf "%.2f", $1 + $2}')
  VALID_SAMPLES=$((VALID_SAMPLES + 1))
done

if [[ "$VALID_SAMPLES" -eq 0 ]]; then
  echo "ERROR: No valid CPU samples collected" >&2
  exit 1
fi

AVG_MILLICORES=$(echo "$CPU_SUM $VALID_SAMPLES" | awk '{printf "%.2f", $1 / $2}')
AVG_PCT=$(echo "$AVG_MILLICORES $CPU_LIMIT_MILLICORES" | awk '{printf "%.2f", ($1 / $2) * 100}')

# Determine method note
case "$RUNTIME" in
  hardened)  CPU_NOTE="kubectl top (cgroup CPU). Captures full container overhead." ;;
  kata)      CPU_NOTE="kubectl top (cgroup CPU). Captures guest-side CPU only; host-side kata-shim + QEMU CPU not included." ;;
  kubevirt)  CPU_NOTE="kubectl top on virt-launcher pod (cgroup CPU). Includes QEMU + libvirt." ;;
esac

cat <<EOF > "$OUTFILE"
{
  "runtime": "${RUNTIME}",
  "idle_cpu_millicores": ${AVG_MILLICORES},
  "idle_cpu_percent": ${AVG_PCT},
  "cpu_limit_millicores": ${CPU_LIMIT_MILLICORES},
  "samples": ${VALID_SAMPLES},
  "interval_seconds": ${INTERVAL},
  "measurement_method": "kubectl_top",
  "notes": "${CPU_NOTE}",
$(platform_json),
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

echo ""
echo "  Average idle CPU: ${AVG_MILLICORES}m (${AVG_PCT}% of ${CPU_LIMIT_MILLICORES}m limit)"
echo "  Note: ${CPU_NOTE}"
echo "  Written to: ${OUTFILE}"
