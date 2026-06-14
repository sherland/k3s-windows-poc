#!/usr/bin/env bash
# =============================================================================
# packer/linux/scripts/03-export-kubeconfig.sh
# Copies the k3s kubeconfig to a world-readable location so the host can
# retrieve it via SCP.  The server IP placeholder is left as-is here;
# Build-LinuxVM.ps1 replaces it with the actual VM IP after the build.
# =============================================================================

set -euo pipefail

KUBECONFIG_SRC='/etc/rancher/k3s/k3s.yaml'
KUBECONFIG_EXPORT='/home/k8sadmin/k3s.yaml'

echo "==> 03-export-kubeconfig: Copying kubeconfig for host retrieval"

if [ ! -f "$KUBECONFIG_SRC" ]; then
    echo "ERROR: $KUBECONFIG_SRC not found — did k3s install succeed?"
    exit 1
fi

cp "$KUBECONFIG_SRC" "$KUBECONFIG_EXPORT"
chown k8sadmin:k8sadmin "$KUBECONFIG_EXPORT"
chmod 600 "$KUBECONFIG_EXPORT"

echo "==> 03-export-kubeconfig: kubeconfig written to $KUBECONFIG_EXPORT"

# Also make the node-token readable by the admin user (host reads it via SSH)
TOKEN_SRC='/var/lib/rancher/k3s/server/node-token'
if [ -f "$TOKEN_SRC" ]; then
    cp "$TOKEN_SRC" /home/k8sadmin/node-token
    chown k8sadmin:k8sadmin /home/k8sadmin/node-token
    chmod 600 /home/k8sadmin/node-token
    echo "==> 03-export-kubeconfig: node-token written to /home/k8sadmin/node-token"
fi

echo "==> 03-export-kubeconfig: Done"
