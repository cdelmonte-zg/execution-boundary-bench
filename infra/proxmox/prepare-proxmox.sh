#!/usr/bin/env bash
#
# prepare-proxmox.sh — One-time Proxmox host preparation for bench cluster
#
# Usage:
#   ./prepare-proxmox.sh <proxmox-host-ip>
#
# What it does:
#   1. Enables "snippets" content type on the "local" storage
#   2. Ensures ip_forward is enabled (persistent)
#   3. Adds MASQUERADE NAT rule for VM internet access (persistent)
#   4. Creates an API token for Terraform (if not already present)
#
# Assumes:
#   - SSH key-based root access to the Proxmox host
#   - Proxmox VE 7.x or 8.x
#
# After running this script, copy the displayed API token into
# your terraform.tfvars file, then run: terraform apply

set -euo pipefail

PROXMOX_IP="${1:?Usage: $0 <proxmox-host-ip>}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -q"

echo "=== Preparing Proxmox host at ${PROXMOX_IP} ==="

ssh ${SSH_OPTS} "root@${PROXMOX_IP}" bash -s "${PROXMOX_IP}" <<'REMOTE_SCRIPT'
set -euo pipefail
PROXMOX_IP="$1"

# -------------------------------------------------------------------
# 1. Enable snippets on "local" storage
# -------------------------------------------------------------------
echo ""
echo "--- Enabling snippets on 'local' storage ---"

CURRENT_CONTENT=$(pvesm status --storage local 2>/dev/null | awk 'NR==2{print $5}' || true)
if echo "$CURRENT_CONTENT" | grep -q snippets; then
  echo "  Snippets already enabled"
else
  # Read current content types and add snippets
  CONTENT=$(pvesh get /storage/local --output-format json 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('content',''))" 2>/dev/null || echo "iso,vztmpl,backup")
  pvesh set /storage/local --content "${CONTENT},snippets" 2>/dev/null
  echo "  Snippets enabled (content: ${CONTENT},snippets)"
fi

# -------------------------------------------------------------------
# 2. Enable persistent ip_forward
# -------------------------------------------------------------------
echo ""
echo "--- Enabling ip_forward ---"

if grep -q '^net.ipv4.ip_forward.*=.*1' /etc/sysctl.conf 2>/dev/null; then
  echo "  ip_forward already enabled in sysctl.conf"
else
  # Uncomment existing line or add new one
  if grep -q '#.*net.ipv4.ip_forward' /etc/sysctl.conf; then
    sed -i 's/#.*net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  else
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
  echo "  ip_forward enabled in sysctl.conf"
fi
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# -------------------------------------------------------------------
# 3. Add persistent MASQUERADE rule for VM NAT
# -------------------------------------------------------------------
echo ""
echo "--- Configuring NAT (MASQUERADE) ---"

# Determine the subnet from the Proxmox host IP
SUBNET=$(echo "$PROXMOX_IP" | sed 's/\.[0-9]*$/.0\/24/')
BRIDGE="vmbr0"

if grep -q MASQUERADE /etc/network/interfaces 2>/dev/null; then
  echo "  MASQUERADE rule already in /etc/network/interfaces"
else
  # Add post-up rule to the bridge interface
  sed -i "/iface ${BRIDGE} inet/,/^$/{
    /bridge-fd/a\\
\\tpost-up iptables -t nat -A POSTROUTING -s ${SUBNET} -o ${BRIDGE} -j MASQUERADE
  }" /etc/network/interfaces
  echo "  MASQUERADE rule added to /etc/network/interfaces"
fi

# Apply immediately if not already active
if ! iptables -t nat -C POSTROUTING -s "${SUBNET}" -o "${BRIDGE}" -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s "${SUBNET}" -o "${BRIDGE}" -j MASQUERADE
  echo "  MASQUERADE rule activated"
else
  echo "  MASQUERADE rule already active"
fi

# -------------------------------------------------------------------
# 4. Create Terraform API token (if not present)
# -------------------------------------------------------------------
echo ""
echo "--- Checking API token ---"

if pveum user token list root@pam 2>/dev/null | grep -q terraform; then
  echo "  API token 'root@pam!terraform' already exists"
  echo "  (if you lost the secret, delete and recreate it)"
else
  echo "  Creating API token 'root@pam!terraform'..."
  TOKEN_OUTPUT=$(pveum user token add root@pam terraform --privsep 0 2>&1)
  echo "$TOKEN_OUTPUT"
  echo ""
  echo "  Copy the token value into your terraform.tfvars:"
  echo "  proxmox_api_token = \"root@pam!terraform=<secret>\""
fi

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
echo ""
echo "=== Proxmox host prepared ==="
echo ""
echo "Next steps:"
echo "  1. Edit infra/proxmox/terraform.tfvars with your settings"
echo "  2. Ensure your SSH key is on the Proxmox host: ssh-copy-id root@${PROXMOX_IP}"
echo "  3. cd infra/proxmox && terraform init && terraform apply"
echo "  4. Run post-provision.sh (see output of terraform apply)"

REMOTE_SCRIPT
