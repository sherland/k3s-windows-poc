#!/usr/bin/env bash
# =============================================================================
# packer/linux/scripts/03-cloud-init-clean.sh
# Wipe cloud-init state so that each differencing disk clone (with its own
# per-node seed ISO) is treated as a fresh instance on first boot.
#
# Without this, cloud-init would see the Packer-build instance-id cached in
# /var/lib/cloud/ and skip re-initialization on the clone.
# =============================================================================
set -euo pipefail

echo "[cloud-init-clean] Cleaning cloud-init state..."
cloud-init clean --logs --seed

# Remove the machine-id so each clone gets a unique one on first boot
# (critical for DHCP to give distinct leases)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

echo "[cloud-init-clean] Done."
