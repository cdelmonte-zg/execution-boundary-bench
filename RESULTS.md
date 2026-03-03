# Reference Results: Proxmox Homelab (March 2026)

Measured on 2026-03-03. Full machine-readable data in `results/2026-03-proxmox/`.

## Summary

| Metric | Hardened Container | Kata Micro-VM | KubeVirt Full VM |
|--------|------------------:|-------------:|-----------------:|
| Cold Start P50 | 1,873 ms | 2,887 ms | 171,303 ms |
| Cold Start P95 | 1,918 ms | 3,892 ms | 176,788 ms |
| App RSS | 61.0 MiB | 56.3 MiB | 57.1 MiB |
| Host Memory | 53 MiB | 419 MiB | 580 MiB |
| Memory Amplification | 0.87x | 7.44x | 10.16x |
| Idle CPU | 1.83m | 1.00m | 2.00m |
| Max Concurrent/Node | 37 | 10 | N/A |

## Key Takeaways

**Cold start.** Containers boot in ~1.9s. Kata adds ~1s (micro-VM + guest kernel). KubeVirt takes ~171s — a full Ubuntu boot with cloud-init inside nested QEMU. The P95/P50 ratio is tight for all three (1.02x, 1.35x, 1.03x), indicating stable, predictable overhead.

**Memory amplification.** The application uses ~57-61 MiB RSS across all runtimes (same Python workload). But the host pays 53 MiB for a container, 419 MiB for Kata (shim + QEMU + virtiofsd), and 580 MiB for KubeVirt (QEMU + libvirt + guest OS). Kata's 7.4x and KubeVirt's 10.2x amplification are the real cost of VM-level isolation.

**Density.** On a 16 GB node: 37 hardened containers vs 10 Kata micro-VMs before saturation. A 3.7x density penalty for VM isolation. KubeVirt density was not tested (each VM requires 512 MiB minimum — the guest OS alone exceeds 128 MiB).

**Idle CPU.** Negligible across all runtimes (1-2 millicores). Not a differentiator.

## Kata Bimodal Cold Start

Kata cold start shows a bimodal distribution: ~3.9s for the first ~15 runs, then ~2.9s for subsequent runs. This is a host-side kernel/page cache warming effect — the guest kernel image and virtiofs metadata get cached after repeated launches. The P95 (3,892 ms) captures the cold-cache mode; the P50 (2,887 ms) reflects warm-cache steady state.

## Environment

| | |
|---|---|
| **CPU** | AMD Ryzen 9 7950X (4 vCPU per node) |
| **RAM** | 16 GB per node |
| **Nodes** | 3 (1 control plane + 2 workers) |
| **Kubernetes** | v1.29.15 |
| **Container runtime** | containerd 1.7.28 |
| **OS** | Ubuntu 22.04.5 LTS |
| **Kernel** | 5.15.0-171-generic |
| **Infrastructure** | Proxmox VMs with `cpu: host` passthrough (nested virtualization) |

### Nested virtualization caveat

Kata and KubeVirt run inside Proxmox VMs, so their absolute numbers include nested virtualization overhead. On bare-metal KVM, cold start and memory values would be marginally lower. **Relative ratios between runtimes are representative** — the hierarchy (container < micro-VM < full VM) holds on any hardware.

## Test Conditions

- **50 runs** per runtime for cold start (0 timeouts across all 150 runs)
- **Images pre-pulled** via warmup run before timed measurements
- **Cluster idle** during all benchmarks (no competing workloads)
- **Cold start CPU**: patched to 1000m to avoid CFS throttling (steady-state manifests use 100m)
- **Memory stabilization**: 30s wait after readiness before sampling (3 samples, median)
- **CPU sampling**: 6 samples at 10s intervals (60s idle observation)
- **Percentiles**: nearest-rank (ceil), no interpolation

### Measurement methodology

| Runtime | Host memory source | CPU source |
|---------|-------------------|------------|
| Hardened container | `kubectl top` (cgroup `working_set_bytes`) | `kubectl top` (cgroup CPU) |
| Kata micro-VM | Privileged host probe: sum of VmRSS for `kata-shim` + `qemu-system` + `virtiofsd` | `kubectl top` (guest-side only) |
| KubeVirt full VM | `kubectl top` on `virt-launcher` pod (includes QEMU + libvirt) | `kubectl top` on `virt-launcher` pod |

## Reproduction

```bash
# On a cluster with KVM support (see README.md for setup)
make benchmark RUNS=50
```

Machine-readable results: `results/2026-03-proxmox/*.json` and `*.csv`.
