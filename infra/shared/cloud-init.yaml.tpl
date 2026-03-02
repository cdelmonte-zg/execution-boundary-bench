#cloud-config
#
# Bootstrap script for benchmark cluster nodes.
# Shared between GCP and Proxmox — injected via Terraform templatefile().
#
# Inputs (Terraform variables):
#   node_role        : "control-plane" | "worker"
#   control_plane_ip : IP of the control plane (empty for control-plane nodes)
#   join_token       : kubeadm join token (empty for control-plane nodes)
#   cert_hash        : discovery-token-ca-cert-hash (empty for control-plane nodes)
#   k8s_version      : e.g. "1.29"
#   pod_cidr         : e.g. "10.244.0.0/16"
#   ssh_public_key   : SSH public key for the bench user
#   hostname         : unique hostname for this node

hostname: ${hostname}
manage_etc_hosts: true

users:
  - name: bench
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}

package_update: true
package_upgrade: false

packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gpg
  - containerd
  - socat
  - conntrack
  - ebtables
  - qemu-guest-agent

write_files:
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter

  - path: /etc/sysctl.d/k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1

  - path: /opt/bench/setup-k8s.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      echo "=== Loading kernel modules ==="
      modprobe overlay
      modprobe br_netfilter
      sysctl --system > /dev/null 2>&1

      echo "=== Disabling swap ==="
      swapoff -a
      sed -i '/swap/d' /etc/fstab

      echo "=== Configuring containerd ==="
      mkdir -p /etc/containerd
      containerd config default > /etc/containerd/config.toml
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      systemctl restart containerd
      systemctl enable containerd

      echo "=== Installing kubeadm/kubelet/kubectl ==="
      mkdir -p /etc/apt/keyrings
      curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${k8s_version}/deb/Release.key" | \
        gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${k8s_version}/deb/ /" > \
        /etc/apt/sources.list.d/kubernetes.list
      apt-get update -qq
      apt-get install -y -qq kubelet kubeadm kubectl
      apt-mark hold kubelet kubeadm kubectl

      %{ if node_role == "control-plane" ~}
      echo "=== Initializing control plane ==="
      kubeadm init --pod-network-cidr=${pod_cidr} 2>&1

      # kubeconfig for root
      mkdir -p /root/.kube
      cp /etc/kubernetes/admin.conf /root/.kube/config

      # kubeconfig for the default user
      USER_HOME=$(getent passwd 1000 | cut -d: -f6) || true
      if [[ -n "$USER_HOME" ]]; then
        mkdir -p "$USER_HOME/.kube"
        cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
        chown -R 1000:1000 "$USER_HOME/.kube"
      fi

      export KUBECONFIG=/etc/kubernetes/admin.conf

      # CNI
      kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

      # Metrics server
      kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
      kubectl patch deployment metrics-server -n kube-system \
        --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null || true

      # Allow scheduling on control plane
      kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

      # Save join command for workers
      kubeadm token create --print-join-command > /opt/bench/join-command.sh
      chmod 644 /opt/bench/join-command.sh

      echo "=== Control plane ready ==="
      %{ else ~}
      echo "=== Joining cluster ==="
      kubeadm join ${control_plane_ip}:6443 \
        --token ${join_token} \
        --discovery-token-ca-cert-hash ${cert_hash}
      echo "=== Worker joined ==="
      %{ endif ~}

runcmd:
  - systemctl enable --now qemu-guest-agent
  - bash /opt/bench/setup-k8s.sh
