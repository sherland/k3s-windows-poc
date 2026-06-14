#!/usr/bin/env bash
# =============================================================================
# packer/linux/scripts/01-base.sh
# Base system hardening and package installation.
# Runs as root (sudo -S) inside the Ubuntu VM during Packer provisioning.
# =============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> 01-base: apt update + upgrade"
apt-get update -y
apt-get upgrade -y --no-install-recommends

echo "==> 01-base: Install required packages"
apt-get install -y --no-install-recommends \
    curl \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    apt-transport-https \
    open-iscsi \
    nfs-common \
    iptables \
    ipset \
    jq \
    unzip \
    net-tools \
    socat \
    conntrack

echo "==> 01-base: Enable open-iscsi (required by k3s local-path storage)"
systemctl enable iscsid 2>/dev/null || true
systemctl start  iscsid 2>/dev/null || true

echo "==> 01-base: Load required kernel modules"
modprobe overlay   2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

echo "==> 01-base: Sysctl settings for k8s networking"
cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "==> 01-base: Disable swap (k3s requirement)"
swapoff -a
sed -i '/\bswap\b/d' /etc/fstab

echo "==> 01-base: Clean apt cache"
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "==> 01-base: Done"
