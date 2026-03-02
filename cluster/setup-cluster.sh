#!/usr/bin/env bash
#
# setup-cluster.sh — Cluster provisioning reference for isolation benchmark
#
# This script is meant to be SOURCED, not executed directly.
#
# Usage:
#   source cluster/setup-cluster.sh
#   setup_node       # on each node — installs containerd, kubeadm, KVM modules
#   init_cluster     # on control plane — initializes K8s cluster
#   install_kata     # on each node — installs Kata Containers runtime
#   install_kubevirt # on control plane — installs KubeVirt operator
#   deploy_seccomp   # on control plane — deploys seccomp profile to all nodes
#
# Assumptions:
#   - Ubuntu 22.04 LTS
#   - KVM available (bare metal or cloud instance with KVM support)
#   - Root or sudo access

set -euo pipefail

KATA_VERSION="${KATA_VERSION:-3.27.0}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.2.0}"
K8S_VERSION="${K8S_VERSION:-1.29}"
SECCOMP_PROFILE_PATH="/var/lib/kubelet/seccomp/profiles"

# ============================================================
# setup_node — Run on each node
# ============================================================
setup_node() {
  echo "=== Setting up node ==="

  # Disable swap (required for kubelet)
  sudo swapoff -a
  sudo sed -i '/swap/d' /etc/fstab

  # Load required kernel modules
  cat <<'MODULES' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
kvm
kvm_intel
MODULES
  sudo modprobe overlay
  sudo modprobe br_netfilter
  sudo modprobe kvm
  sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true

  # Sysctl params for Kubernetes networking
  cat <<'SYSCTL' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL
  sudo sysctl --system > /dev/null

  # Install containerd
  sudo apt-get update -qq
  sudo apt-get install -y -qq containerd
  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl restart containerd
  sudo systemctl enable containerd

  # Install kubeadm, kubelet, kubectl
  sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq kubelet kubeadm kubectl
  sudo apt-mark hold kubelet kubeadm kubectl

  # Install metrics-server dependency (needed for kubectl top)
  echo "  Node setup complete."
}

# ============================================================
# init_cluster — Run on control plane only
# ============================================================
init_cluster() {
  echo "=== Initializing cluster ==="

  sudo kubeadm init --pod-network-cidr=10.244.0.0/16

  mkdir -p "$HOME/.kube"
  sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

  # Install Calico CNI
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

  # Install metrics-server (required for kubectl top)
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # Patch for single-node / self-signed certs
  kubectl patch deployment metrics-server -n kube-system \
    --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
    2>/dev/null || true

  # Allow scheduling on control plane (for single-node or small clusters)
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

  echo "=== Cluster initialized ==="
  echo ""
  echo "Join command for worker nodes:"
  kubeadm token create --print-join-command
}

# ============================================================
# install_kata — Run on each node (after cluster init)
# ============================================================
install_kata() {
  echo "=== Installing Kata Containers ==="

  # Verify KVM is available
  if [[ ! -e /dev/kvm ]]; then
    echo "ERROR: /dev/kvm not available. KVM support required for Kata." >&2
    return 1
  fi

  # Install Kata using official release tarball
  sudo apt-get install -y -qq zstd
  local kata_url="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-amd64.tar.zst"
  echo "  Downloading Kata ${KATA_VERSION}..."
  curl -fsSL "$kata_url" | sudo tar --zstd -xf - -C /

  # Configure containerd to use Kata as a runtime
  if ! grep -q 'containerd.runtimes.kata' /etc/containerd/config.toml 2>/dev/null; then
    cat <<'KATA' | sudo tee -a /etc/containerd/config.toml > /dev/null

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
  privileged_without_host_devices = true
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata.options]
    ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration.toml"
KATA
    sudo systemctl restart containerd
  fi

  # Create RuntimeClass in Kubernetes (run from a node with kubectl access)
  kubectl apply -f - <<'RUNTIMECLASS'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
overhead:
  podFixed:
    memory: "160Mi"
    cpu: "250m"
RUNTIMECLASS

  echo "=== Kata Containers installed ==="
}

# ============================================================
# install_kubevirt — Run on control plane only
# ============================================================
install_kubevirt() {
  echo "=== Installing KubeVirt ${KUBEVIRT_VERSION} ==="

  kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
  kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"

  echo "  Waiting for KubeVirt to be ready (up to 5 minutes)..."
  kubectl wait --for=condition=Available kubevirt kubevirt -n kubevirt --timeout=300s

  # Install virtctl CLI
  local virtctl_url="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64"
  echo "  Installing virtctl..."
  sudo curl -fsSL "$virtctl_url" -o /usr/local/bin/virtctl
  sudo chmod +x /usr/local/bin/virtctl

  echo "=== KubeVirt installed ==="
}

# ============================================================
# deploy_seccomp — Deploy custom seccomp profile to all nodes
# ============================================================
deploy_seccomp() {
  echo "=== Deploying seccomp profile ==="

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local profile_src="${script_dir}/../manifests/seccomp-profile.json"

  if [[ ! -f "$profile_src" ]]; then
    echo "ERROR: Seccomp profile not found at ${profile_src}" >&2
    return 1
  fi

  local profile_content
  profile_content=$(cat "$profile_src")

  for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    echo "  Deploying to node: ${node}"

    # Use a privileged pod to write the seccomp profile to the node's filesystem
    kubectl run "seccomp-deploy-${node}" \
      --image=busybox:1.36 \
      --restart=Never \
      --overrides="{
        \"spec\": {
          \"nodeName\": \"${node}\",
          \"containers\": [{
            \"name\": \"deploy\",
            \"image\": \"busybox:1.36\",
            \"command\": [\"sh\", \"-c\", \"mkdir -p ${SECCOMP_PROFILE_PATH} && cat > ${SECCOMP_PROFILE_PATH}/bench-seccomp.json\"],
            \"stdin\": true,
            \"stdinOnce\": true,
            \"securityContext\": {\"privileged\": true},
            \"volumeMounts\": [{\"name\": \"host-kubelet\", \"mountPath\": \"${SECCOMP_PROFILE_PATH}\"}]
          }],
          \"volumes\": [{\"name\": \"host-kubelet\", \"hostPath\": {\"path\": \"${SECCOMP_PROFILE_PATH}\", \"type\": \"DirectoryOrCreate\"}}],
          \"restartPolicy\": \"Never\"
        }
      }" 2>/dev/null <<< "$profile_content" || true

    # Wait for pod to complete and clean up
    kubectl wait --for=condition=Ready "pod/seccomp-deploy-${node}" --timeout=30s 2>/dev/null || true
    sleep 2
    kubectl delete pod "seccomp-deploy-${node}" --grace-period=0 --force 2>/dev/null || true
  done

  echo "=== Seccomp profile deployed to ${SECCOMP_PROFILE_PATH}/bench-seccomp.json ==="
}

# ============================================================
# If executed directly, show usage
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "This script is meant to be sourced, not executed directly."
  echo ""
  echo "Usage:"
  echo "  source $0"
  echo ""
  echo "Available functions:"
  echo "  setup_node       Install containerd, kubeadm, KVM modules"
  echo "  init_cluster     Initialize Kubernetes cluster"
  echo "  install_kata     Install Kata Containers runtime"
  echo "  install_kubevirt Install KubeVirt operator"
  echo "  deploy_seccomp   Deploy custom seccomp profile to all nodes"
fi
