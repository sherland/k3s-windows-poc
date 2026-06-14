#!/usr/bin/env bash
# =============================================================================
# packer/linux/scripts/02-install-k3s-binary.sh
# Install the k3s binary (only) into the golden base image.
#
# Environment:
#   K3S_VERSION  — e.g. v1.32.5+k3s1 (set by Packer build provisioner)
#
# IMPORTANT: INSTALL_K3S_SKIP_ENABLE=true  → no systemd unit created
#            INSTALL_K3S_SKIP_START=true   → k3s is NOT started
# The binary lands at /usr/local/bin/k3s and is ready for use by differencing
# disk clones that run Bootstrap-ControlPlane.ps1 or Join-Nodes.ps1.
# =============================================================================
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.32.5+k3s1}"

echo "[k3s-binary] Installing k3s binary ${K3S_VERSION} (skip enable + skip start)..."

curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_SKIP_ENABLE=true \
    INSTALL_K3S_SKIP_START=true \
    sh -

# Verify the binary is present
if [[ ! -x /usr/local/bin/k3s ]]; then
    echo "[k3s-binary] ERROR: /usr/local/bin/k3s not found after install" >&2
    exit 1
fi

echo "[k3s-binary] Done — k3s binary at $(/usr/local/bin/k3s --version | head -1)"
