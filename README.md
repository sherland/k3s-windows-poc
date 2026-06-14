# Hyper-V Kubernetes Cluster (k3s: Linux master + Windows worker)

Automates building a minimal k3s cluster on a Windows 11 host using Hyper-V.  
Two VMs are created via Packer and joined into a single cluster:

| VM | OS | Role | CPU | RAM |
|----|----|------|-----|-----|
| `k8s-linux-master` | Ubuntu 24.04 LTS | k3s server (control plane + Linux node) | 2 | 4 GB |
| `k8s-windows-worker` | Windows Server 2025 Core | k3s agent (Windows worker node) | 4 | 7 GB |

Both VMs attach to an external Hyper-V vSwitch and receive IPs from your router's DHCP.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Host OS | Windows 11 or Windows Server 2022/2025 |
| CPU | Nested virtualisation capable (Intel VT-x / AMD SVM) |
| RAM | ≥ 16 GB (32 GB recommended) |
| Free disk | ≥ 60 GB (each VM is ~60 GB, plus ISO + Packer cache) |
| Network | Internet access for ISO download, apt packages, k3s binaries |
| winget | Shipped with Windows 11 App Installer |

Phase 0 of the build script automatically installs all remaining software (Hyper-V, Packer, kubectl, OpenSSH).

---

## Quick Start

### 1. Configure credentials and sizing

Edit [`config/variables.ps1`](config/variables.ps1) **before the first run**:

```powershell
# Change default passwords
$script:LinuxAdminUser  = 'k8sadmin'
$script:LinuxAdminPass  = 'ChangeMe123!'
$script:WinAdminUser    = 'Administrator'
$script:WinAdminPass    = 'ChangeMe123!'
```

> ⚠️ The default credentials (`k8sadmin` / `ChangeMe123!`) are only suitable for local development.

### 2. (Optional) Verify your system

```powershell
.\check-system.ps1
```

Checks admin rights, disk space, Hyper-V, and required tools.

### 3. Build the cluster

```powershell
# Run as Administrator (wrapper handles elevation automatically)
.\run-elevated.ps1
```

Or, if you are already in an elevated shell:

```powershell
.\scripts\Main.ps1
```

**Total build time**: 45–90 minutes on first run (most time is Windows ISO download and VM provisioning).

Progress is logged to `output/run.log` (when using `run-elevated.ps1`).

### 4. Access the cluster

```powershell
$env:KUBECONFIG = "$PWD\output\kubeconfig.yaml"
kubectl get nodes -o wide
```

Expected output: two nodes (`k8s-linux-master` + `k8s-windows-worker`), both `Ready`.

---

## Recreating the Cluster

### Resume after a failure

Each phase writes a sentinel file to `output/sentinels/`. Completed phases are skipped automatically on re-run.

```powershell
# Resume from where it stopped
.\scripts\Main.ps1

# Explicitly resume from phase 4
.\scripts\Main.ps1 -StartFromPhase 4
```

### Force specific phases to re-run

```powershell
# Re-run only phases 2 and 4 (Linux build + Windows build)
.\scripts\Main.ps1 -ForcePhase 2,4
```

### Full rebuild from scratch

1. Delete the cluster (see below).
2. Run the build again from the top.

```powershell
.\scripts\Remove-Cluster.ps1 -All
.\run-elevated.ps1
```

---

## Deleting the Cluster

`scripts/Remove-Cluster.ps1` tears down resources in a granular way.

```powershell
# Remove everything (VMs + disks, vSwitch, output files, cached downloads)
.\scripts\Remove-Cluster.ps1 -All

# Remove only VMs and their virtual disks
.\scripts\Remove-Cluster.ps1 -VMs

# Remove only the Hyper-V vSwitch
.\scripts\Remove-Cluster.ps1 -Network

# Remove only generated output files (kubeconfig, SSH keys, sentinel files)
.\scripts\Remove-Cluster.ps1 -OutputFiles

# Remove only cached downloads (ISO, Packer cache)
.\scripts\Remove-Cluster.ps1 -Downloads

# Combine flags
.\scripts\Remove-Cluster.ps1 -VMs -Network -OutputFiles

# Dry-run (shows what would be deleted, makes no changes)
.\scripts\Remove-Cluster.ps1 -All -WhatIf
```

---

## Phase Reference

| Phase | Name | What Happens | Typical Duration |
|-------|------|-------------|-----------------|
| 0 | Host Prerequisites | Install Hyper-V, Packer, kubectl, OpenSSH; may auto-reboot | 5–15 min |
| 1 | Hyper-V vSwitch | Create external vSwitch bound to primary NIC | < 1 min |
| 2 | Build Linux VM | Packer builds Ubuntu 24.04, installs k3s server | 8–12 min |
| 3 | Download Windows ISO | Download ~5 GB WS 2025 Core eval ISO from Microsoft | 5–20 min |
| 4 | Build Windows VM | Packer builds WS 2025, installs containerd + k3s agent | 15–25 min |
| 5 | Export kubeconfig | Copy k3s.yaml from Linux VM, patch server IP | < 1 min |
| 6 | Join Windows node | Wait for Windows node to appear in `kubectl get nodes` | 2–5 min |

All phases are **idempotent** — safe to re-run; already-completed phases are skipped.

---

## Advanced Usage

### Health check (no changes)

```powershell
.\scripts\Main.ps1 -HealthCheckOnly
```

### Force re-run all phases (full rebuild without deleting VMs)

```powershell
.\scripts\Main.ps1 -ForcePhase 0,1,2,3,4,5,6
```

### Override host NIC (if auto-detection picks the wrong adapter)

In `config/variables.ps1`:

```powershell
$script:HostNicName = 'Ethernet'   # exact name from Get-NetAdapter
```

---

## Network & Cluster Details

| Setting | Value |
|---------|-------|
| Hyper-V vSwitch | `k8s-external` (external, bridges to host NIC) |
| Pod CIDR | `10.42.0.0/16` |
| Service CIDR | `10.43.0.0/16` |
| CoreDNS IP | `10.43.0.10` |
| CNI | Flannel `host-gw` (L2, no VXLAN overhead) |
| kubeconfig | `output/kubeconfig.yaml` |
| Cluster info | `output/cluster-info.txt` |

---

## Repository Layout

```
.
├── config/
│   └── variables.ps1          # Central config: credentials, VM sizing, versions
├── docs/
│   └── plan-k8sHyperVCluster.prompt.md   # Architecture and design decisions
├── output/                    # Generated at runtime (gitignored sensitive files)
│   ├── kubeconfig.yaml
│   ├── cluster-info.txt
│   └── sentinels/             # Phase completion markers
├── packer/
│   ├── linux/ubuntu.pkr.hcl   # Ubuntu 24.04 Packer template
│   └── windows/winserver.pkr.hcl  # Windows Server 2025 Packer template
├── scripts/
│   ├── Main.ps1               # Primary orchestrator
│   ├── Remove-Cluster.ps1     # Cluster teardown
│   ├── Helpers.ps1            # Shared utilities (logging, SSH, retry, phases)
│   └── ...                    # Per-phase scripts
├── check-system.ps1           # Pre-flight system checks
└── run-elevated.ps1           # Elevation wrapper (auto-elevates + logs)
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Phase 0 triggers a reboot | Normal — Hyper-V requires a reboot. Re-run after reboot. |
| Phase 3 stalls (ISO download) | Check internet connectivity; the MS Eval Center can be slow. |
| Windows VM fails to join | Re-run `.\scripts\Main.ps1 -StartFromPhase 5`; WinRM timeout may need extending in `config/variables.ps1`. |
| `kubectl` can't connect | Verify `$env:KUBECONFIG` is set to `output/kubeconfig.yaml`; check VM IP with `output/linux-vm-ip.txt`. |
| Wrong NIC selected for vSwitch | Set `$script:HostNicName` in `config/variables.ps1`. |

See [`docs/architecture.md`](docs/architecture.md) for component layout, networking internals, and the full build sequence.
See [`docs/plan-k8sHyperVCluster.prompt.md`](docs/plan-k8sHyperVCluster.prompt.md) for architecture decisions and design rationale.
