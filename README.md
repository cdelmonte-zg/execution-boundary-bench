# Isolation Benchmark: Containers vs Micro-VMs vs Full VMs on Kubernetes

Reproducible benchmark comparing isolation overhead across three Kubernetes execution models for multi-tenant code execution platforms.

Companion repository for: **"Containers Are Not a Security Boundary. Designing Secure Multi-Tenant Code Execution on Kubernetes."**

## What This Measures

| Metric | Definition | Source |
|--------|-----------|--------|
| Cold start P50/P95 | `kubectl apply` → readiness probe OK | Wall clock (100 runs) |
| Application RSS | Memory used by the workload process | VmRSS from `/proc/self/status` inside sandbox |
| Host memory | Total host memory committed to sandbox | `kubectl top` (cgroup) or host process probe (Kata) |
| Memory amplification | Host memory / Application RSS | Computed |
| Idle CPU | CPU consumed by idle sandbox | `kubectl top` (millicores) |
| Max concurrent/node | Sandboxes before OOM or node pressure | Linear ramp to saturation |

### Measurement methodology

**Hardened containers and KubeVirt**: `kubectl top` reports cgroup `working_set_bytes`. For containers, the cgroup IS the host-level view. For KubeVirt, we measure the `virt-launcher` pod which contains QEMU + libvirt.

**Kata Containers**: `kubectl top` only sees guest-side metrics (what the VM reports internally), missing the real host cost. We deploy a privileged probe pod with `hostPID: true` to sum VmRSS of `kata-shim` + `qemu-system` + `virtiofsd` processes on the host — the actual host-level memory footprint.

Note: `kubectl top` reports `working_set_bytes` (= usage - inactive_file), which can be slightly **less** than the application's self-reported VmRSS due to shared library pages. An amplification factor < 1.0x for hardened containers is expected and correct.

## What This Does NOT Measure

- Application throughput (irrelevant to isolation cost)
- CPU-heavy workload performance
- Network throughput between sandboxes

This is **isolation cost modeling**, not performance engineering.

## Execution Models

| Model | Runtime | Kernel | Isolation Boundary | Memory Limit |
|-------|---------|--------|--------------------|-------------|
| Hardened container | containerd + custom seccomp | Shared | Namespace + seccomp | 128Mi |
| Micro-VM | Kata Containers | Dedicated guest | VM boundary | 128Mi |
| Full VM | KubeVirt | Dedicated guest + full OS | Hardware virtualization | 512Mi |

KubeVirt requires 512Mi because the guest OS (Ubuntu 22.04) + QEMU + cloud-init overhead exceeds 128Mi. This asymmetry is itself a data point: full VM isolation has a minimum memory floor that containers don't.

## Prerequisites

### Local machine
- Terraform >= 1.5
- SSH key pair (`~/.ssh/id_rsa` or equivalent)
- `kubectl`

### Target environment (pick one)

| | Proxmox (homelab) | GCP |
|---|---|---|
| **Use for** | Primary — reproducible on your hardware | Bare-metal cloud validation |
| **Nodes** | 3× VM (4 vCPU, 16 GB) | 3× `n2-standard-4` (4 vCPU, 16 GB) |
| **KVM** | `cpu: host` passthrough (nested virt) | Native KVM (no nesting) |
| **OS** | Ubuntu 22.04 (cloud image) | Ubuntu 22.04 (cloud image) |
| **Cost** | Free | ~$0.38/h total (~$2 per full run) |
| **Proxmox version** | 5.2+ (cloud-init support) | — |

### A note on nested virtualization

Kata and KubeVirt run inside Proxmox VMs, so their absolute numbers reflect nested virtualization overhead. On bare-metal KVM, cold start and memory values would be marginally lower. **Relative ratios between runtimes are representative** — a container doesn't become faster than Kata on different hardware. The repo includes GCP Terraform for anyone wanting to validate on bare-metal cloud.

### Why not kind/k3s/minikube?

The benchmark measures Kata Containers and KubeVirt, which require real KVM. kind/k3s/minikube don't support hardware virtualization runtimes.

### Why 2 workers if benchmarks run one pod at a time?

Cold start, memory, and CPU benchmarks measure a single sandbox. The scheduler distributes pods across both workers freely — this doesn't affect results since workers are identical VMs. The second worker keeps cluster infrastructure (KubeVirt operator, Calico, metrics-server) from competing with benchmark pods for resources. The `max-concurrent` test pins all pods to a single worker via `nodeName` to measure per-node density.

## Quick Start

### Option A: Proxmox (homelab)

```bash
# 0. Prepare Proxmox host (one-time)
cd infra/proxmox
./prepare-proxmox.sh <proxmox-host-ip>

# 1. Provision infrastructure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set proxmox_endpoint, api_token, node, IP range
terraform init && terraform apply

# 2. Install Kata, KubeVirt, seccomp
cd ../shared
./post-provision.sh 192.168.1.200 192.168.1.201 192.168.1.202

# 3. SSH into control plane
ssh bench@192.168.1.200

# 4. Run benchmark
make benchmark

# 5. Tear down when done
cd infra/proxmox && terraform destroy
```

### Option B: GCP (bare-metal cloud)

```bash
# 1. Provision infrastructure
cd infra/gcp
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set project_id, region, ssh key path
terraform init && terraform apply

# 2. Install Kata, KubeVirt, seccomp (post-Terraform)
cd ../shared
./post-provision.sh \
  $(cd ../gcp && terraform output -raw control_plane_external_ip) \
  $(cd ../gcp && terraform output -json worker_external_ips | jq -r '.[]')

# 3. SSH into control plane
ssh bench@$(cd ../gcp && terraform output -raw control_plane_external_ip)

# 4. Run benchmark
make benchmark

# 5. Tear down when done
cd infra/gcp && terraform destroy
```

### Option C: Existing cluster

If you already have a Kubernetes cluster with KVM support:

```bash
# 1. Install runtimes manually
source cluster/setup-cluster.sh
install_kata     # on each node
install_kubevirt # on control plane
deploy_seccomp   # on control plane

# 2. Run benchmark
make benchmark
```

### Individual benchmarks

```bash
make cold-start RUNS=50   # cold start only
make memory                # RSS + host memory + amplification (pods must be running)
make cpu                   # idle CPU overhead (pods must be running)
make concurrent            # max sandboxes per node
```

## Workload

Minimal Python HTTP server (`workload/server.py`):
- ~40 MB RSS baseline (pre-allocated ballast)
- `/ready` endpoint (returns JSON with PID, uptime, RSS)
- `/healthz` endpoint
- No external dependencies
- Deployed via ConfigMap (no container registry required)

The workload is deliberately simple. We measure **sandbox overhead**, not application behavior.

## Test Conditions

Declared and captured in `results/environment.json`:

- **Image pre-pull**: A warmup run (not counted) ensures all images are cached before timed runs begin. Cold start measures scheduling + sandbox boot, not image pull latency.
- **Cluster load**: Idle — no other workloads running during benchmarks.
- **Memory stabilization**: 30s wait after pod ready before measuring RSS.
- **CPU sampling**: 6 samples at 10s intervals (60s total idle observation).
- **Measurement source**: `kubectl top` for hardened/KubeVirt (cgroup metrics), privileged host probe for Kata (VmRSS of shim + QEMU + virtiofsd).
- **Cold start CPU**: Patched to 1000m during cold start to avoid CFS throttling (steady-state manifests use 100m).
- **Percentiles**: Nearest-rank (ceil). P95 = value at index `ceil(n × 0.95)`. No interpolation.
- **Memory units**: All memory values are MiB (mebibytes, binary). `kubectl top` reports MiB; host probe converts from KiB.

## Repository Structure

```
├── Makefile                          # Build, benchmark targets
├── infra/
│   ├── shared/
│   │   ├── cloud-init.yaml.tpl       # Cloud-init template (both environments)
│   │   └── post-provision.sh         # SSH-based Kata/KubeVirt/seccomp installer
│   ├── gcp/
│   │   ├── main.tf                   # GCE instances + VPC
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── terraform.tfvars.example
│   └── proxmox/
│       ├── main.tf                   # Proxmox VMs via bpg/proxmox provider
│       ├── variables.tf
│       ├── outputs.tf
│       ├── prepare-proxmox.sh        # One-time Proxmox host preparation
│       └── terraform.tfvars.example
├── cluster/
│   └── setup-cluster.sh              # Manual setup (for existing clusters)
├── manifests/
│   ├── hardened-container.yaml       # Pod: containerd + seccomp (128Mi)
│   ├── kata-microvm.yaml             # Pod: Kata RuntimeClass (128Mi)
│   ├── kubevirt-vm.yaml              # VM: KubeVirt (512Mi)
│   └── seccomp-profile.json          # Custom seccomp allowlist (~90 syscalls)
├── workload/
│   ├── Dockerfile
│   └── server.py                     # Benchmark workload (~40MB RSS)
├── scripts/
│   ├── lib-env.sh                    # Platform info capture (sourced by all scripts)
│   ├── cold-start.sh                 # Cold start latency (CSV + JSON)
│   ├── memory-baseline.sh            # RSS + host memory + amplification (JSON)
│   ├── cpu-overhead.sh               # Idle CPU overhead (JSON)
│   ├── max-concurrent.sh             # Saturation test (JSON)
│   └── run-all.sh                    # Full suite orchestrator
└── results/                          # Output directory (gitignored)
    ├── environment.json              # Captured environment + test conditions
    ├── cold-start-*.csv              # Per-runtime cold start data
    ├── memory-*.json                 # Per-runtime memory measurements
    ├── cpu-*.json                    # Per-runtime CPU measurements
    └── max-concurrent-*.json         # Per-runtime saturation data
```

## Interpreting Results

The benchmark produces a summary table:

```
Metric                   Hardened         Kata     KubeVirt
----------------------  ------------  ------------  ------------
Cold Start P50 (ms)          ...          ...          ...
Cold Start P95 (ms)          ...          ...          ...
App RSS (MiB)                ...          ...          ...
Host Memory (MiB)            ...          ...          ...
Amplification                ...x         ...x         ...x
Idle CPU (m)                 ...          ...          ...
Idle CPU (%)                 ...          ...          ...
Max Concurrent/Node          ...          ...          N/A
```

**Key metrics to watch:**
- **Amplification > 1.0x**: Overhead beyond what the application needs. Higher for VM-based isolation.
- **P95/P50 ratio > 2.0**: Indicates cold start instability.
- **Max concurrent**: Direct capacity planning input. The ratio between runtimes shows cost-of-isolation in terms of density.

## License

MIT
