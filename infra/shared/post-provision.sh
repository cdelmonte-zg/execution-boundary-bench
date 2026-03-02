#!/usr/bin/env bash
#
# post-provision.sh — Install Kata + KubeVirt + seccomp after Terraform
#
# Usage:
#   ./post-provision.sh <control-plane-ip> [worker-ip...]
#
# This script SSHs into the nodes and completes what cloud-init started:
#   1. Waits for cloud-init and kubeadm to finish
#   2. Retrieves the join command from the control plane
#   3. Joins workers to the cluster
#   4. Installs Kata Containers on all nodes
#   5. Installs KubeVirt on the control plane
#   6. Deploys the seccomp profile to all nodes
#
# Assumes:
#   - SSH key-based auth configured (ssh-agent or key in default path)
#   - User "bench" on all nodes (matches cloud-init)
#   - Nodes already running from Terraform

set -euo pipefail

SSH_USER="${SSH_USER:-bench}"
SSH_KEY="${SSH_KEY:-}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -q"
[[ -n "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
KATA_VERSION="${KATA_VERSION:-3.27.0}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.2.0}"

CONTROL_PLANE_IP="${1:?Usage: $0 <control-plane-ip> [worker-ip...]}"
shift
WORKER_IPS=("$@")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECCOMP_PROFILE="${SCRIPT_DIR}/../../manifests/seccomp-profile.json"
SECCOMP_DEST="/var/lib/kubelet/seccomp/profiles/bench-seccomp.json"

ssh_cmd() {
  local ip="$1"
  shift
  ssh ${SSH_OPTS} "${SSH_USER}@${ip}" "$@"
}

scp_cmd() {
  scp ${SSH_OPTS} "$@"
}

# -------------------------------------------------------------------
# Step 1: Wait for cloud-init to complete on all nodes
# -------------------------------------------------------------------
echo "=== Waiting for cloud-init to finish ==="

wait_cloud_init() {
  local ip="$1"
  local name="$2"
  local retries=0
  local max_retries=60  # 10 minutes

  while true; do
    local status
    status=$(ssh_cmd "$ip" "cloud-init status 2>/dev/null || true" 2>/dev/null | grep -oP 'status: \K\S+' || echo "pending")
    if [[ "$status" == "done" || "$status" == "error" ]]; then
      # "error" is expected on workers: cloud-init tries kubeadm join with
      # PLACEHOLDER token which fails. The rest (containerd, kubeadm install)
      # has completed. post-provision.sh handles the real join in step 2.
      echo "  ${name} (${ip}): cloud-init ${status}"
      return 0
    fi
    retries=$((retries + 1))
    if [[ "$retries" -ge "$max_retries" ]]; then
      echo "  ${name} (${ip}): cloud-init timed out" >&2
      return 1
    fi
    sleep 10
  done
}

wait_cloud_init "$CONTROL_PLANE_IP" "control-plane"
for i in "${!WORKER_IPS[@]}"; do
  wait_cloud_init "${WORKER_IPS[$i]}" "worker-$((i+1))"
done

# -------------------------------------------------------------------
# Step 2: Get join command from control plane and join workers
# -------------------------------------------------------------------
echo ""
echo "=== Joining workers to cluster ==="

JOIN_CMD=$(ssh_cmd "$CONTROL_PLANE_IP" "sudo cat /opt/bench/join-command.sh 2>/dev/null || sudo kubeadm token create --print-join-command")

for i in "${!WORKER_IPS[@]}"; do
  ip="${WORKER_IPS[$i]}"
  echo "  Joining worker-$((i+1)) (${ip})..."

  # Check if already joined
  if ssh_cmd "$ip" "sudo kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get nodes" &>/dev/null; then
    echo "  worker-$((i+1)) already joined, skipping"
    continue
  fi

  ssh_cmd "$ip" "sudo ${JOIN_CMD}"
  echo "  worker-$((i+1)) joined"
done

# Wait for all nodes to be Ready
echo "  Waiting for all nodes to be Ready..."
ssh_cmd "$CONTROL_PLANE_IP" "
  export KUBECONFIG=/home/${SSH_USER}/.kube/config
  kubectl wait --for=condition=Ready nodes --all --timeout=180s
"
echo "  All nodes ready"

# -------------------------------------------------------------------
# Step 3: Install Kata Containers on all nodes
# -------------------------------------------------------------------
echo ""
echo "=== Installing Kata Containers ${KATA_VERSION} ==="

KATA_TARBALL="kata-static-${KATA_VERSION}-amd64.tar.zst"
KATA_URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/${KATA_TARBALL}"

# Download once on control plane, then distribute to workers via SCP.
# This avoids requiring internet access on worker nodes.
echo "  Downloading ${KATA_TARBALL} on control plane..."
ssh_cmd "$CONTROL_PLANE_IP" "
  set -euo pipefail
  sudo apt-get install -y -qq zstd
  if [[ ! -f /tmp/${KATA_TARBALL} ]]; then
    curl -fsSL '${KATA_URL}' -o /tmp/${KATA_TARBALL}
  fi
"

install_kata_on_node() {
  local ip="$1"
  local name="$2"

  echo "  Installing on ${name} (${ip})..."

  # Check if already installed
  if ssh_cmd "$ip" "test -f /opt/kata/bin/kata-runtime" 2>/dev/null; then
    echo "    Kata already installed, skipping"
    return 0
  fi

  # Verify KVM
  if ! ssh_cmd "$ip" "test -e /dev/kvm" 2>/dev/null; then
    echo "  ERROR: /dev/kvm not available on ${name}" >&2
    return 1
  fi

  # Copy tarball to worker via local machine as relay
  # (CP doesn't have SSH keys to reach workers directly)
  if [[ "$ip" != "$CONTROL_PLANE_IP" ]]; then
    if [[ ! -f "/tmp/${KATA_TARBALL}" ]]; then
      echo "    Downloading tarball from CP to local machine..."
      scp_cmd "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/${KATA_TARBALL}" "/tmp/${KATA_TARBALL}"
    fi
    echo "    Uploading tarball to ${name}..."
    scp_cmd "/tmp/${KATA_TARBALL}" "${SSH_USER}@${ip}:/tmp/${KATA_TARBALL}"
  fi

  # Extract and configure
  ssh_cmd "$ip" "
    set -euo pipefail
    sudo apt-get install -y -qq zstd
    sudo tar --zstd -xf /tmp/${KATA_TARBALL} -C /

    # Symlink shim binary so containerd can find it
    sudo ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2

    # Add Kata runtime to containerd
    if ! grep -q 'containerd.runtimes.kata' /etc/containerd/config.toml; then
      sudo tee -a /etc/containerd/config.toml > /dev/null <<'KATACONF'

[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.kata]
  runtime_type = \"io.containerd.kata.v2\"
  privileged_without_host_devices = true
  [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.kata.options]
    ConfigPath = \"/opt/kata/share/defaults/kata-containers/configuration.toml\"
KATACONF
      sudo systemctl restart containerd
    fi
    echo '    Kata installed'
  "
}

install_kata_on_node "$CONTROL_PLANE_IP" "control-plane"
for i in "${!WORKER_IPS[@]}"; do
  install_kata_on_node "${WORKER_IPS[$i]}" "worker-$((i+1))"
done

# Clean up cached tarballs
ssh_cmd "$CONTROL_PLANE_IP" "rm -f /tmp/${KATA_TARBALL}" 2>/dev/null || true
rm -f "/tmp/${KATA_TARBALL}" 2>/dev/null || true

# Create Kata RuntimeClass
echo "  Creating Kata RuntimeClass..."
ssh_cmd "$CONTROL_PLANE_IP" "
  export KUBECONFIG=/home/${SSH_USER}/.kube/config
  kubectl apply -f - <<'RUNTIMECLASS'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
overhead:
  podFixed:
    memory: \"160Mi\"
    cpu: \"250m\"
RUNTIMECLASS
"

# -------------------------------------------------------------------
# Step 4: Install KubeVirt
# -------------------------------------------------------------------
echo ""
echo "=== Installing KubeVirt ${KUBEVIRT_VERSION} ==="

ssh_cmd "$CONTROL_PLANE_IP" "
  set -euo pipefail
  export KUBECONFIG=/home/${SSH_USER}/.kube/config

  # Check if already installed
  if kubectl get kubevirt kubevirt -n kubevirt &>/dev/null; then
    echo '  KubeVirt already installed, skipping'
    exit 0
  fi

  kubectl create -f 'https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml'
  kubectl create -f 'https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml'

  echo '  Waiting for KubeVirt to be ready (up to 5 minutes)...'
  kubectl wait --for=condition=Available kubevirt kubevirt -n kubevirt --timeout=300s

  # Install virtctl
  sudo curl -fsSL \
    'https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64' \
    -o /usr/local/bin/virtctl
  sudo chmod +x /usr/local/bin/virtctl

  echo '  KubeVirt installed'
"

# -------------------------------------------------------------------
# Step 5: Deploy seccomp profile
# -------------------------------------------------------------------
echo ""
echo "=== Deploying seccomp profile ==="

if [[ ! -f "$SECCOMP_PROFILE" ]]; then
  echo "ERROR: Seccomp profile not found at ${SECCOMP_PROFILE}" >&2
  exit 1
fi

deploy_seccomp_to_node() {
  local ip="$1"
  local name="$2"

  echo "  Deploying to ${name} (${ip})..."
  scp_cmd "$SECCOMP_PROFILE" "${SSH_USER}@${ip}:/tmp/bench-seccomp.json"
  ssh_cmd "$ip" "
    sudo mkdir -p $(dirname ${SECCOMP_DEST})
    sudo mv /tmp/bench-seccomp.json ${SECCOMP_DEST}
  "
}

deploy_seccomp_to_node "$CONTROL_PLANE_IP" "control-plane"
for i in "${!WORKER_IPS[@]}"; do
  deploy_seccomp_to_node "${WORKER_IPS[$i]}" "worker-$((i+1))"
done

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
echo ""
echo "============================================="
echo "  Cluster ready for benchmarks"
echo "============================================="
echo ""
echo "  Control plane: ssh ${SSH_USER}@${CONTROL_PLANE_IP}"
echo ""
echo "  Next steps:"
echo "    1. SSH into control plane"
echo "    2. Clone the benchmark repo"
echo "    3. make benchmark    # run full suite"
echo ""
