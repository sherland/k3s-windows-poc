# Hyper-V k3s Cluster — Multi-Node, Multi-CNI Edition

Automates building a configurable k3s cluster on a single Windows 11 host using Hyper-V differencing disks. Supports multiple topology scenarios with different CNI plugins:

| Scenario | Script | CNI | Nodes | Verified |
|----------|--------|-----|-------|---------|
| A | `Run-ScenarioA.ps1` | Flannel (embedded) | CP + 2 Linux + 1 Windows (WS2022) | PASS (04:38) |
| B | `Run-ScenarioB.ps1` | Multus v4.3.0 + Flannel + macvlan | CP + 2 Linux | PASS (04:22) |
| C | `Run-ScenarioC.ps1` | Cilium v1.19.5 + Hubble | CP + 2 Linux | 28/28 PASS (06:39) |
| D | `Run-ScenarioD.ps1` | Calico v3.32.0 | CP + 2 Linux | 28/28 PASS (05:12) |
| E | `Run-ScenarioE.ps1` | Flannel + chained Cilium + Hubble | CP + 2 Linux + 1 Windows (WS2022) | 38/38 PASS (06:35) |

Architecture uses **Hyper-V differencing disks**: golden base VHDXs are built once by Packer, then each node VM gets a child differencing disk created in seconds.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Host OS | Windows 11 (Hyper-V capable) |
| CPU | Intel VT-x / AMD SVM with nested virtualisation |
| RAM | ≥ 16 GB (32 GB recommended for Windows worker) |
| Free disk | ≥ 80 GB (Linux base ~8 GB, Windows base ~25 GB, nodes ~5 GB each) |
| Network | Internet access for ISO/binary downloads |
| winget | Shipped with Windows 11 App Installer |

Phase 0 automatically installs all remaining tooling (Hyper-V, Packer, kubectl, OpenSSH, Windows ADK).

---

## Quick Start — Run a Scenario

All scenario scripts handle teardown, config patching, full build, and verification in one command. Run from an **elevated** PowerShell shell:

```powershell
# Scenario A: Flannel + CP + 2 Linux workers + 1 Windows worker (WS2022)
.\Run-ScenarioA.ps1

# Scenario B: Multus + Flannel + CP + 2 Linux workers, no Windows
.\Run-ScenarioB.ps1

# Scenario C: Cilium + Hubble + CP + 2 Linux workers, no Windows
.\Run-ScenarioC.ps1

# Scenario D: Calico + CP + 2 Linux workers, no Windows
.\Run-ScenarioD.ps1

# Scenario E: Flannel + chained Cilium + Hubble + CP + 2 Linux workers + 1 Windows worker
.\Run-ScenarioE.ps1

# Run all 5 scenarios in sequence (with teardown after the last one)
.\Run-AllScenarios.ps1 -CleanupAfterAll

# Run a subset
.\Run-AllScenarios.ps1 -Scenarios A,C,E
```

Add `-DeleteGoldenImages` to force a full Packer rebuild of base VHDXs (needed when changing k3s version, base OS packages, etc.):

```powershell
.\Run-ScenarioA.ps1 -DeleteGoldenImages
```

Add `-SkipCleanup` to skip teardown (re-run a scenario without destroying an existing cluster):

```powershell
.\Run-ScenarioC.ps1 -SkipCleanup
```

> ⚠️ The default credentials (`k8sadmin` / `ChangeMe123!`) are only suitable for local development. Change them in [`config/variables.ps1`](config/variables.ps1) before use.

---

## Manual Cluster Build

If you want fine-grained control, patch `config/variables.ps1` and drive the orchestrator directly:

### 1. Configure topology

Edit [`config/variables.ps1`](config/variables.ps1):

```powershell
# CNI plugin: 'flannel' | 'multus' | 'cilium' | 'calico' | 'none'
$script:CNIPlugin = 'flannel'

# Windows workers (set Count=0 for Linux-only cluster)
$script:WindowsNodeSpecs = @(
    @{ Count = 1; OSVersion = '2022'; CPU = 4; RAM = 7168 }
)

# Linux worker count
$script:LinuxWorkerCount = 1
```

### 2. Run all phases

```powershell
# From an elevated shell
.\scripts\Main.ps1
```

### 3. Access the cluster

```powershell
$env:KUBECONFIG = "$PWD\output\kubeconfig.yaml"
kubectl get nodes -o wide
```
> **Changing networks?** The VMs get their IPs from DHCP, so the control-plane IP in the kubeconfig — and in each worker's k3s-agent config — becomes stale when you move between networks (e.g. home ↔ office). Run `Update-KubeConfig.ps1` to fix both without touching the cluster:
> ```powershell
> .\Update-KubeConfig.ps1
> ```
> This patches `output/kubeconfig.yaml` **and** SSHes into each Linux worker to update `K3S_URL` and restart `k3s-agent`, so nodes return to `Ready`.

---

## CNI Plugin Reference

| CNI | Value | Notes |
|-----|-------|-------|
| Flannel | `'flannel'` | Default. Required for Windows workers. k3s embedded, host-gw mode. |
| Multus | `'multus'` | Meta-CNI on top of Flannel. Linux-only. Adds NetworkAttachmentDefinition (NAD) CRD. Enables multi-homed pods via secondary interfaces. Phase 8 installs `containernetworking/plugins` (macvlan, ipvlan, etc.) on every node alongside the Multus DaemonSet — these binaries are required for secondary CNI delegation and are not bundled with k3s. Scenario B tests macvlan: pods get a second interface (`net1`) with its own MAC address, directly visible on the L2 segment. |
| Cilium | `'cilium'` | Full CNI replacement. Linux-only. Replaces Flannel (`--flannel-backend=none`). Hubble relay+UI enabled. Installed via Helm. |
| Flannel + Cilium | `'flannel+cilium'` | Flannel handles routing (incl. Windows workers); Cilium chained for eBPF observability on Linux nodes. Hubble relay+UI enabled. Installed via Helm post-join. |
| Calico | `'calico'` | Full CNI replacement. Linux-only. Replaces Flannel (`--flannel-backend=none`). Installed via Helm (tigera-operator). |

**Phase ordering note:** For Cilium and Calico, the CNI must be installed *before* workers join (nodes stay `NotReady` without a CNI). For `flannel+cilium`, all nodes join first (Flannel provides routing), then Cilium is chained in post-join. `Main.ps1` handles this ordering automatically for all three.

---

## Recreating / Resuming

```powershell
# Resume from where it stopped (sentinels skip completed phases)
.\scripts\Main.ps1

# Resume from a specific phase
.\scripts\Main.ps1 -StartFromPhase 6

# Force specific phases to re-run
.\scripts\Main.ps1 -ForcePhase 7,8

# Re-join a specific node
.\scripts\Main.ps1 -ForceNode k8s-win-01

# Skip Windows nodes at runtime
.\scripts\Main.ps1 -SkipWindowsNodes
```

---

## Scaling Linux Workers

Once a cluster is running you can add or remove Linux workers without touching the rest of the cluster. `variables.ps1` is updated automatically after each operation.

```powershell
# Scale up to 3 workers (creates k8s-lnx-03, joins it)
.\Scale-LinuxWorkers.ps1 -TargetCount 3

# Scale down to 1 worker (drains k8s-lnx-02 first, then removes it)
.\Scale-LinuxWorkers.ps1 -TargetCount 1

# Force-drain (skip PDB checks — removes pods immediately)
.\Scale-LinuxWorkers.ps1 -TargetCount 1 -DrainTimeoutSec 0

# Preview what would happen without making any changes
.\Scale-LinuxWorkers.ps1 -TargetCount 1 -WhatIf
```

Scale-down sequence per node: `kubectl cordon` → `kubectl drain` → `kubectl delete node` → stop k3s-agent via SSH → remove Hyper-V VM + VHDX + seed ISO → clear sentinels → update `variables.ps1`.

---

## Deleting the Cluster

```powershell
# Remove VMs + node VHDXs + output files (keep base images and ISOs)
.\scripts\Remove-Cluster.ps1 -VMs -OutputFiles -Force

# Remove everything including base VHDXs and cached ISOs
.\scripts\Remove-Cluster.ps1 -All -Force

# Keep base images (faster next run — skip Packer rebuild)
.\scripts\Remove-Cluster.ps1 -VMs -OutputFiles -KeepBaseImages -Force

# Dry-run (shows what would be deleted, no changes)
.\scripts\Remove-Cluster.ps1 -All -WhatIf
```

---

## Phase Reference

| Phase | Script | What Happens | Typical Duration |
|-------|--------|-------------|-----------------|
| 0 | `Install-Prerequisites.ps1` | Hyper-V, Packer, kubectl, OpenSSH, Windows ADK | < 5 min |
| 1 | `New-HyperVSwitch.ps1` | Create external vSwitch | < 1 min |
| BASE-L | `Build-LinuxBase.ps1` | Packer builds Ubuntu 24.04 + k3s binary | 7–10 min |
| BASE-W | `Build-WindowsBase.ps1` | Packer builds WS2022 + containerd + kubelet | 15–25 min |
| 4 | `New-LinuxNodes.ps1` | Differencing disks + cloud-init seed ISOs | < 1 min |
| 5 | `New-WindowsNodes.ps1` | Differencing disks for Windows nodes | < 1 min |
| 6 | `Bootstrap-ControlPlane.ps1` | k3s server + RBAC + credentials export | 1–3 min |
| 7 | `Join-Nodes.ps1` | Linux workers (SSH) + Windows workers (VMBus) | 1–5 min |
| 8 | `Apply-CNI.ps1` | Apply CNI plugin (Multus/Cilium/Calico; no-op for Flannel) | 1–5 min |
| 9 | `Export-KubeConfig.ps1` | Write `output/kubeconfig.yaml` + `cluster-info.txt` | < 1 min |
| 10 | `Verify-Cluster.ps1` | Cross-node ping, DNS, ClusterIP, CNI health | 1–3 min |

All phases are **idempotent** — sentinel files in `output/sentinels/` skip already-completed work.

---

## Network & Cluster Details

| Setting | Value |
|---------|-------|
| Hyper-V vSwitch | `k8s-external` (external, bridges to host NIC via DHCP) |
| Pod CIDR | `10.42.0.0/16` |
| Service CIDR | `10.43.0.0/16` |
| Flannel backend | `host-gw` (L2, no VXLAN) |
| kubeconfig | `output/kubeconfig.yaml` |
| Cluster info | `output/cluster-info.txt` |

---

## Repository Layout

```
.
├── Run-ScenarioA.ps1          # End-to-end: Flannel + CP + 2 Linux workers + Windows worker
├── Run-ScenarioB.ps1          # End-to-end: Multus + Flannel + CP + 2 Linux workers
├── Run-ScenarioC.ps1          # End-to-end: Cilium + Hubble + CP + 2 Linux workers
├── Run-ScenarioD.ps1          # End-to-end: Calico + CP + 2 Linux workers
├── Run-ScenarioE.ps1          # End-to-end: Flannel + chained Cilium + Hubble + CP + 2 Linux workers + Windows worker
├── Run-AllScenarios.ps1       # Orchestrates all (or a subset of) scenarios A–E sequentially
├── config/
│   ├── variables.ps1          # Single source of truth: versions, topology, credentials
│   └── cni/
│       ├── multus-daemonset.yaml      # Multus v4.3.0 DaemonSet manifest
│       ├── cilium-values.yaml         # Cilium v1.19.4 Helm values (Hubble enabled)
│       ├── cilium-chained-values.yaml # Cilium chained-mode values for Scenario E
│       └── calico-values.yaml         # Calico v3.29.3 tigera-operator Helm values
├── docs/
│   └── architecture.md        # Component layout, networking, build sequence
├── output/                    # Generated at runtime
│   ├── kubeconfig.yaml
│   ├── cluster-info.txt
│   ├── node-token.txt
│   ├── admin-kubeconfig.yaml
│   ├── flannel-kubeconfig.yaml
│   ├── seed-isos/             # Per-node cloud-init ISOs
│   └── sentinels/             # Phase completion markers
├── packer/
│   ├── linux/ubuntu.pkr.hcl   # Ubuntu 24.04 + k3s binary base image
│   └── windows/winserver.pkr.hcl  # WS2022/WS2025 + containerd + kubelet base image
├── scripts/
│   ├── Main.ps1               # 10-phase orchestrator
│   ├── Remove-Cluster.ps1     # Granular teardown
│   ├── Helpers.ps1            # Shared utilities
│   ├── Bootstrap-ControlPlane.ps1
│   ├── Join-Nodes.ps1
│   ├── Apply-CNI.ps1
│   ├── Verify-Cluster.ps1
│   └── ...                    # Other per-phase scripts
├── vhdx/
│   ├── linux-base/            # Golden Ubuntu base VHDX (read-only)
│   ├── win2022-base/          # Golden WS2022 base VHDX (read-only)
│   └── nodes/                 # Per-node differencing disks
├── check-system.ps1           # Pre-flight system checks
├── Scale-LinuxWorkers.ps1     # Scale Linux workers up/down post-cluster (drain → delete → remove VM)
├── Test-ScaleLinuxWorkers.ps1 # End-to-end test for Scale-LinuxWorkers.ps1 (0→4→3→1 + 6 invariants per step)
├── Update-KubeConfig.ps1      # Refresh kubeconfig + fix worker k3s-agent after changing networks (home <-> office)
└── run-elevated.ps1           # Elevation wrapper + log tee
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Phase 0 triggers a reboot | Normal — Hyper-V requires reboot. Re-run after reboot; sentinels preserve progress. |
| Packer build fails (SSH timeout) | Usually a transient cloud-init timing issue; re-run with `-ForcePhase BASE-L`. |
| Windows VM fails to join | Re-run `.\scripts\Main.ps1 -ForceNode k8s-win-01`; check `C:\k8s-firstboot-log.txt` inside the VM. |
| Nodes stay `NotReady` (Cilium/Calico) | Phase ordering: CNI must deploy before workers join. This is handled automatically; re-run from phase 7 if disrupted. |
| Hubble flows not captured | Hubble observe reads the per-node ring buffer; if no traffic has been generated yet, run cross-node tests first. The verification script (`Verify-Cluster.ps1`) generates traffic before querying Hubble. |
| `kubectl` can't connect / workers `NotReady` after changing networks | Run `.\Update-KubeConfig.ps1` — patches the kubeconfig and restarts `k3s-agent` on all workers with the new CP IP. |
| `kubectl` can't connect | Verify `$env:KUBECONFIG` points to `output/kubeconfig.yaml`; check `output/linux-vm-ip.txt`. |
| Wrong NIC for vSwitch | Set `$script:HostNicName` in `config/variables.ps1`. |
| SSH key mismatch after rebuild | Delete `output/linux-build-key*` and re-run — `Build-LinuxBase.ps1` regenerates and patches user-data automatically. |
| containerd v2.x error | Must use v1.7.x — v2.x removed the CRI v1 API required by kubelet. Pin is in `config/variables.ps1`. |

See [`docs/architecture.md`](docs/architecture.md) for full component layout, networking internals, and build sequence.
