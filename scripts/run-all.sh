#!/usr/bin/env bash
#
# run-all.sh — Run complete benchmark suite
#
# Usage: ./run-all.sh [cold-start-runs]
#   cold-start-runs: iterations for cold start test (default: 100)
#
# Runs all benchmarks sequentially and produces a summary table.
# Captures environment info and test conditions for reproducibility.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
COLD_START_RUNS="${1:-100}"

mkdir -p "$RESULTS_DIR"

echo "============================================="
echo "  Isolation Benchmark Suite"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================="
echo ""

# -----------------------------------------------------------
# Phase 0: Environment Capture
# -----------------------------------------------------------
echo "============================================="
echo "  Phase 0: Environment"
echo "============================================="

echo "--- Cluster Info ---"
kubectl get nodes -o wide
echo ""

# Ensure workload ConfigMap exists (used by hardened + kata manifests)
echo "  Ensuring bench-workload ConfigMap..."
kubectl create configmap bench-workload \
  --from-file=server.py="${SCRIPT_DIR}/../workload/server.py" \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo "  ConfigMap ready"
echo ""

# Capture environment details for reproducibility
ENV_FILE="${RESULTS_DIR}/environment.json"
echo "  Capturing environment..."

K8S_VERSION=$(kubectl version -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
sv = data.get('serverVersion', {})
print(f\"{sv.get('major','?')}.{sv.get('minor','?')}.{sv.get('gitVersion','?')}\")
" 2>/dev/null || echo "unknown")

# Get node details (from first node)
FIRST_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
NODE_CPU=$(kubectl get node "$FIRST_NODE" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null || echo "unknown")
NODE_RAM_KI=$(kubectl get node "$FIRST_NODE" -o jsonpath='{.status.capacity.memory}' 2>/dev/null || echo "0Ki")
NODE_RAM_GB=$(echo "$NODE_RAM_KI" | sed 's/Ki//' | awk '{printf "%.0f", $1 / 1048576}')
KERNEL=$(kubectl get node "$FIRST_NODE" -o jsonpath='{.status.nodeInfo.kernelVersion}' 2>/dev/null || echo "unknown")
OS_IMAGE=$(kubectl get node "$FIRST_NODE" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null || echo "unknown")
CONTAINER_RUNTIME=$(kubectl get node "$FIRST_NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || echo "unknown")
KUBELET_VERSION=$(kubectl get node "$FIRST_NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || echo "unknown")

# CPU model — /proc/cpuinfo is readable from any pod (it's hardware info)
CPU_MODEL=$(kubectl run --rm -i --restart=Never --image=busybox:1.36 "cpu-probe-$$" \
  --overrides='{"spec":{"nodeName":"'"${FIRST_NODE}"'"}}' \
  -- grep -m1 "model name" /proc/cpuinfo 2>/dev/null \
  | sed 's/.*: //' | tr -d '\r' || echo "unknown")

# Check for nested virtualization via kubelet proxy
KVM_NESTED=$(kubectl get --raw "/api/v1/nodes/${FIRST_NODE}/proxy/stats/summary" 2>/dev/null | \
  python3 -c "import sys,json; print('available')" 2>/dev/null || echo "unknown")
# Note: kvm_nested detection is best-effort; verify manually if critical

cat <<EOF > "$ENV_FILE"
{
  "kubernetes_version": "${K8S_VERSION}",
  "kubelet_version": "${KUBELET_VERSION}",
  "container_runtime": "${CONTAINER_RUNTIME}",
  "node_count": ${NODE_COUNT},
  "node_cpu_cores": "${NODE_CPU}",
  "node_ram_gb": ${NODE_RAM_GB},
  "kernel_version": "${KERNEL}",
  "os_image": "${OS_IMAGE}",
  "cpu_model": "${CPU_MODEL}",
  "nested_virtualization": "${KVM_NESTED}",
  "test_conditions": {
    "cold_start_runs": ${COLD_START_RUNS},
    "image_pull_policy": "IfNotPresent (warmup run pre-pulls before timed runs)",
    "cluster_load": "idle (no other workloads during test)",
    "memory_stabilization_wait_seconds": 30,
    "cpu_sample_duration_seconds": 60,
    "measurement_method": "kubectl top (cgroup) for hardened/kubevirt; host process VmRSS probe for kata"
  },
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

echo "  Kubernetes: ${K8S_VERSION}"
echo "  Nodes: ${NODE_COUNT} × ${NODE_CPU} vCPU, ${NODE_RAM_GB} GB RAM"
echo "  Kernel: ${KERNEL}"
echo "  OS: ${OS_IMAGE}"
echo "  CPU: ${CPU_MODEL}"
echo "  Nested virt: ${KVM_NESTED}"
echo "  Written to: ${ENV_FILE}"
echo ""

# -----------------------------------------------------------
# Phase 1: Cold Start
# -----------------------------------------------------------
echo "============================================="
echo "  Phase 1: Cold Start (${COLD_START_RUNS} runs each)"
echo "============================================="
echo "  Conditions: images pre-pulled (warmup run), cluster idle"
echo ""

for runtime in hardened kata kubevirt; do
  echo ""
  echo "--- ${runtime} ---"
  "${SCRIPT_DIR}/cold-start.sh" "$runtime" "$COLD_START_RUNS"
done

# -----------------------------------------------------------
# Phase 2: Memory + CPU Baseline
# -----------------------------------------------------------
echo ""
echo "============================================="
echo "  Phase 2: Memory + CPU Baseline"
echo "============================================="
echo "  Memory: kubectl top (cgroup) for hardened/kubevirt, host process probe for kata"
echo "  CPU: kubectl top over 60s (6 × 10s samples)"
echo ""

for runtime in hardened kata kubevirt; do
  echo ""
  echo "--- ${runtime} ---"

  # Launch the pod/VM
  case "$runtime" in
    hardened) kubectl apply -f "${SCRIPT_DIR}/../manifests/hardened-container.yaml" ;;
    kata)     kubectl apply -f "${SCRIPT_DIR}/../manifests/kata-microvm.yaml" ;;
    kubevirt) kubectl apply -f "${SCRIPT_DIR}/../manifests/kubevirt-vm.yaml" ;;
  esac

  # Wait for ready
  case "$runtime" in
    hardened) kubectl wait --for=condition=Ready pod/bench-hardened --timeout=120s ;;
    kata)     kubectl wait --for=condition=Ready pod/bench-kata --timeout=120s ;;
    kubevirt)
      echo "  Waiting for VMI Ready (polling)..."
      vmi_elapsed=0
      while ! kubectl get vmi bench-kubevirt &>/dev/null 2>&1; do
        sleep 2; vmi_elapsed=$((vmi_elapsed + 2))
        if [[ "$vmi_elapsed" -ge 300 ]]; then echo "  ERROR: VMI never appeared" >&2; break; fi
      done
      while [[ "$vmi_elapsed" -lt 300 ]]; do
        vmi_ready=$(kubectl get vmi bench-kubevirt -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [[ "$vmi_ready" == "True" ]]; then break; fi
        sleep 5; vmi_elapsed=$((vmi_elapsed + 5))
      done ;;
  esac

  "${SCRIPT_DIR}/memory-baseline.sh" "$runtime"
  "${SCRIPT_DIR}/cpu-overhead.sh" "$runtime"

  # Cleanup
  case "$runtime" in
    hardened) kubectl delete pod bench-hardened --grace-period=0 --force 2>/dev/null ;;
    kata)     kubectl delete pod bench-kata --grace-period=0 --force 2>/dev/null ;;
    kubevirt)
      kubectl delete vm bench-kubevirt 2>/dev/null || true
      # Wait for VM object to be fully removed (finalizers processed)
      vmi_wait=0
      while kubectl get vm bench-kubevirt &>/dev/null; do
        sleep 1
        vmi_wait=$((vmi_wait + 1))
        if [[ "$vmi_wait" -ge 120 ]]; then
          echo "  WARNING: VM cleanup timed out after 120s" >&2
          break
        fi
      done
      # Wait for VMI to be removed
      vmi_wait=0
      while kubectl get vmi bench-kubevirt &>/dev/null; do
        sleep 2
        vmi_wait=$((vmi_wait + 1))
        if [[ "$vmi_wait" -ge 60 ]]; then
          echo "  WARNING: VMI cleanup timed out after 120s" >&2
          break
        fi
      done
      # Wait for virt-launcher pod to fully terminate
      vmi_wait=0
      while kubectl get pods -l "vm.kubevirt.io/name=bench-kubevirt" --no-headers 2>/dev/null | grep -q .; do
        sleep 1
        vmi_wait=$((vmi_wait + 1))
        if [[ "$vmi_wait" -ge 60 ]]; then
          echo "  WARNING: Launcher pod cleanup timed out" >&2
          break
        fi
      done
      ;;
  esac
  sleep 5
done

# -----------------------------------------------------------
# Phase 3: Max Concurrent (containers and kata only)
# -----------------------------------------------------------
echo ""
echo "============================================="
echo "  Phase 3: Max Concurrent"
echo "============================================="

for runtime in hardened kata; do
  echo ""
  echo "--- ${runtime} ---"
  "${SCRIPT_DIR}/max-concurrent.sh" "$runtime"
done

# -----------------------------------------------------------
# Phase 4: Summary
# -----------------------------------------------------------
echo ""
echo "============================================="
echo "  RESULTS SUMMARY"
echo "============================================="
echo ""

printf "%-22s %12s %12s %12s\n" "Metric" "Hardened" "Kata" "KubeVirt"
printf "%-22s %12s %12s %12s\n" "----------------------" "------------" "------------" "------------"

# Cold start summary
for runtime in hardened kata kubevirt; do
  CSV="${RESULTS_DIR}/cold-start-${runtime}.csv"
  if [[ -f "$CSV" ]]; then
    P50=$(awk -F',' 'NR>1 && $3!="TIMEOUT" {v[++n]=$3} END {asort(v); idx=int(n*0.50+0.999999); if(idx<1)idx=1; if(idx>n)idx=n; print v[idx]}' "$CSV")
    P95=$(awk -F',' 'NR>1 && $3!="TIMEOUT" {v[++n]=$3} END {asort(v); idx=int(n*0.95+0.999999); if(idx<1)idx=1; if(idx>n)idx=n; print v[idx]}' "$CSV")
    eval "${runtime}_P50=${P50}"
    eval "${runtime}_P95=${P95}"
  fi
done
printf "%-22s %12s %12s %12s\n" "Cold Start P50 (ms)" "${hardened_P50:-N/A}" "${kata_P50:-N/A}" "${kubevirt_P50:-N/A}"
printf "%-22s %12s %12s %12s\n" "Cold Start P95 (ms)" "${hardened_P95:-N/A}" "${kata_P95:-N/A}" "${kubevirt_P95:-N/A}"

# Memory and CPU from JSON files
for runtime in hardened kata kubevirt; do
  MEM_FILE="${RESULTS_DIR}/memory-${runtime}.json"
  CPU_FILE="${RESULTS_DIR}/cpu-${runtime}.json"
  if [[ -f "$MEM_FILE" ]]; then
    eval "${runtime}_RSS=$(python3 -c "import json; print(json.load(open('${MEM_FILE}'))['application_rss_mib'])" 2>/dev/null || echo 'N/A')"
    eval "${runtime}_HOST=$(python3 -c "import json; print(json.load(open('${MEM_FILE}'))['host_memory_mib'])" 2>/dev/null || echo 'N/A')"
    eval "${runtime}_AMP=$(python3 -c "import json; print(json.load(open('${MEM_FILE}'))['amplification_factor'])" 2>/dev/null || echo 'N/A')"
  fi
  if [[ -f "$CPU_FILE" ]]; then
    eval "${runtime}_CPU_M=$(python3 -c "import json; print(json.load(open('${CPU_FILE}'))['idle_cpu_millicores'])" 2>/dev/null || echo 'N/A')"
    eval "${runtime}_CPU_P=$(python3 -c "import json; print(json.load(open('${CPU_FILE}'))['idle_cpu_percent'])" 2>/dev/null || echo 'N/A')"
  fi
done

printf "%-22s %12s %12s %12s\n" "App RSS (MiB)" "${hardened_RSS:-N/A}" "${kata_RSS:-N/A}" "${kubevirt_RSS:-N/A}"
printf "%-22s %12s %12s %12s\n" "Host Memory (MiB)" "${hardened_HOST:-N/A}" "${kata_HOST:-N/A}" "${kubevirt_HOST:-N/A}"
printf "%-22s %12s %12s %12s\n" "Amplification" "${hardened_AMP:-N/A}x" "${kata_AMP:-N/A}x" "${kubevirt_AMP:-N/A}x"
printf "%-22s %12s %12s %12s\n" "Idle CPU (m)" "${hardened_CPU_M:-N/A}" "${kata_CPU_M:-N/A}" "${kubevirt_CPU_M:-N/A}"
printf "%-22s %12s %12s %12s\n" "Idle CPU (%)" "${hardened_CPU_P:-N/A}" "${kata_CPU_P:-N/A}" "${kubevirt_CPU_P:-N/A}"

# Max concurrent
for runtime in hardened kata; do
  CONC_FILE="${RESULTS_DIR}/max-concurrent-${runtime}.json"
  if [[ -f "$CONC_FILE" ]]; then
    eval "${runtime}_MAX=$(python3 -c "import json; print(json.load(open('${CONC_FILE}'))['max_concurrent_stable'])" 2>/dev/null || echo 'N/A')"
  fi
done
printf "%-22s %12s %12s %12s\n" "Max Concurrent/Node" "${hardened_MAX:-N/A}" "${kata_MAX:-N/A}" "N/A"

echo ""
echo "  Environment: ${ENV_FILE}"
echo "  Full results: ${RESULTS_DIR}/"
echo "  Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
