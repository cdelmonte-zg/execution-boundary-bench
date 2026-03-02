#!/usr/bin/env bash
#
# memory-baseline.sh — Measure RSS and memory amplification per runtime
#
# Usage: ./memory-baseline.sh <runtime>
#   runtime: hardened | kata | kubevirt
#
# Requires: pod/VM already running and ready.
# Output: results/memory-<runtime>.json
#
# Definitions:
#   application_rss_mib  = VmRSS reported by the workload process (inside sandbox)
#   host_memory_mib      = total host-side memory consumed by the sandbox
#     - hardened/kubevirt: cgroup working_set via kubectl top (= host memory)
#     - kata: sum of VmRSS of kata-shim + QEMU + virtiofsd on the host node
#       (kubelet stats only see guest-side metrics for Kata, missing host overhead)
#   amplification_factor = host_memory_mib / application_rss_mib

set -euo pipefail

RUNTIME="${1:?Usage: $0 <hardened|kata|kubevirt>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
OUTFILE="${RESULTS_DIR}/memory-${RUNTIME}.json"

mkdir -p "$RESULTS_DIR"

# shellcheck source=lib-env.sh
source "${SCRIPT_DIR}/lib-env.sh"
capture_environment

POD_NAME="bench-${RUNTIME}"

# --- 1. Wait 30s for RSS to stabilize (per spec) ---
echo "  Waiting 30s for RSS stabilization..."
sleep 30

# --- 2. Get application RSS from the /ready endpoint ---
get_app_rss() {
  local runtime="$1"
  local response

  case "$runtime" in
    hardened|kata)
      response=$(kubectl exec "$POD_NAME" -- \
        python3 -c "
import urllib.request, sys
r = urllib.request.urlopen('http://localhost:8080/ready')
sys.stdout.write(r.read().decode())
" 2>/dev/null)
      ;;
    kubevirt)
      local vmi_ip
      vmi_ip=$(kubectl get vmi "$POD_NAME" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null)
      if [[ -z "$vmi_ip" ]]; then
        echo "ERROR: Cannot determine VMI IP for ${POD_NAME}" >&2
        return 1
      fi
      response=$(kubectl run --rm -i --restart=Never --image=busybox:1.36 "rss-probe-$$" -- \
        wget -qO- "http://${vmi_ip}:8080/ready" 2>/dev/null | grep -o '{[^}]*}')
      ;;
  esac

  echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['rss_mb'])"
}

# --- 3. Get host-level memory ---
# Method varies by runtime:
#   hardened/kubevirt: kubectl top (cgroup working_set IS the host view)
#   kata: privileged probe pod to sum VmRSS of host-side processes

get_host_memory_cgroup() {
  # For hardened containers and KubeVirt virt-launcher:
  # kubectl top reports cgroup working_set in MiB — this IS the host memory.
  local target_pod="$1"
  local raw
  raw=$(kubectl top pod "$target_pod" --no-headers 2>/dev/null | awk '{print $3}')
  echo "$raw" | sed 's/[^0-9.]//g'
}

get_host_memory_kata() {
  # For Kata: kubelet stats only see guest-side metrics.
  # Real host cost = kata-shim + QEMU + virtiofsd processes on the node.
  # We deploy a privileged pod with hostPID to read /proc/<pid>/status.
  #
  # The command is embedded in the --overrides JSON because --overrides with
  # explicit containers[] ignores -- args. All " inside the command are escaped
  # as \" (JSON escape), \\0 becomes \0 (null for tr), \\$2 becomes $2 (awk).
  local node="$1"

  kubectl run --rm -i --restart=Never \
    --image=busybox:1.36 \
    --overrides='{"spec":{"nodeName":"'"${node}"'","hostPID":true,"containers":[{"name":"probe","image":"busybox:1.36","securityContext":{"privileged":true},"command":["sh","-c","total_kb=0; for pid in $(ls /proc | grep -E \"^[0-9]+$\"); do comm=$(cat /proc/$pid/comm 2>/dev/null || true); case \"$comm\" in containerd-shim*|qemu-system*|virtiofsd) cmdline=$(cat /proc/$pid/cmdline 2>/dev/null | tr \"\\0\" \" \" || true); case \"$cmdline\" in *kata*|*containerd-shim-kata*) rss_kb=$(grep VmRSS /proc/$pid/status 2>/dev/null | awk \"{print \\$2}\"); if [ -n \"$rss_kb\" ]; then total_kb=$((total_kb + rss_kb)); fi;; esac;; esac; done; echo $((total_kb / 1024))"]}]}}' \
    "kata-mem-probe-$$" 2>/dev/null | grep -E '^[0-9]+$' | tail -1
}

get_host_memory() {
  local runtime="$1"

  case "$runtime" in
    hardened)
      get_host_memory_cgroup "$POD_NAME"
      ;;
    kata)
      local node
      node=$(kubectl get pod "$POD_NAME" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
      echo "  (kata host probe on node: ${node})" >&2
      get_host_memory_kata "$node"
      ;;
    kubevirt)
      local launcher
      launcher=$(kubectl get pods -l "vm.kubevirt.io/name=${POD_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
      if [[ -z "$launcher" ]]; then
        echo "ERROR: Cannot find virt-launcher pod for ${POD_NAME}" >&2
        return 1
      fi
      echo "  (virt-launcher pod: ${launcher})" >&2
      get_host_memory_cgroup "$launcher"
      ;;
  esac
}

# --- Take 3 samples, 10s apart, use median for stability ---
MEM_SAMPLES=3
MEM_INTERVAL=10

echo "  Taking ${MEM_SAMPLES} memory samples (${MEM_INTERVAL}s apart)..."

RSS_VALUES=()
HOST_VALUES=()

for s in $(seq 1 "$MEM_SAMPLES"); do
  if [[ "$s" -gt 1 ]]; then
    sleep "$MEM_INTERVAL"
  fi

  rss=$(get_app_rss "$RUNTIME")
  host=$(get_host_memory "$RUNTIME")
  RSS_VALUES+=("$rss")
  HOST_VALUES+=("$host")
  printf "    Sample %d/%d: RSS=%s MiB, Host=%s MiB\n" "$s" "$MEM_SAMPLES" "$rss" "$host"
done

# Use median (middle value of 3 sorted samples)
APP_RSS=$(printf '%s\n' "${RSS_VALUES[@]}" | sort -n | sed -n '2p')
HOST_MEM=$(printf '%s\n' "${HOST_VALUES[@]}" | sort -n | sed -n '2p')

echo "  Median application RSS: ${APP_RSS} MiB"
echo "  Median host memory: ${HOST_MEM} MiB"

# --- 4. Compute amplification factor ---
AMPLIFICATION=$(echo "$HOST_MEM $APP_RSS" | awk '{
  if ($2 > 0) printf "%.2f", $1 / $2;
  else print "N/A"
}')

# --- 5. Determine measurement method label ---
case "$RUNTIME" in
  hardened)  METHOD="kubectl_top_cgroup_working_set" ;;
  kata)      METHOD="host_process_rss_sum (kata-shim + qemu + virtiofsd)" ;;
  kubevirt)  METHOD="kubectl_top_virt_launcher_working_set" ;;
esac

# --- 6. Output JSON ---
cat <<EOF > "$OUTFILE"
{
  "runtime": "${RUNTIME}",
  "application_rss_mib": ${APP_RSS},
  "host_memory_mib": ${HOST_MEM},
  "amplification_factor": ${AMPLIFICATION},
  "samples": ${MEM_SAMPLES},
  "aggregation": "median",
  "measurement_method": "${METHOD}",
  "notes": {
    "application_rss": "VmRSS from /proc/self/status inside sandbox",
    "host_memory_hardened": "cgroup working_set via kubectl top (= host memory for containers)",
    "host_memory_kata": "sum of VmRSS of kata-shim + qemu-system + virtiofsd on host (privileged probe pod)",
    "host_memory_kubevirt": "cgroup working_set of virt-launcher pod via kubectl top"
  },
$(platform_json),
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

echo ""
echo "  Application RSS:  ${APP_RSS} MiB"
echo "  Host memory:      ${HOST_MEM} MiB"
echo "  Amplification:    ${AMPLIFICATION}x"
echo "  Method:           ${METHOD}"
echo "  Written to: ${OUTFILE}"
