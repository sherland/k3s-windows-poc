# Copilot Instructions — Hyper-V k3s Cluster (Multi-Node, Multi-CNI Edition)

This repo automates building a configurable k3s cluster on a Windows 11 Hyper-V host:
- **1 Linux control-plane** (always) — `k8s-cp-01`
- **N Linux worker nodes** (configurable via `$script:LinuxWorkerCount`) — `k8s-lnx-01`, …
- **N Windows worker nodes** (configurable via `$script:WindowsNodeSpecs`; can be zero) — `k8s-win-01`, …
- **WS2022 and/or WS2025** Windows nodes supported simultaneously

Architecture uses **Hyper-V differencing disks**: golden base VHDXs are built once by Packer, then each node VM gets a child differencing disk created in seconds.

## Validated Scenarios

| Scenario | Script | CNI | Nodes | Result |
|----------|--------|-----|-------|--------|
| A | `Run-ScenarioA.ps1` | Flannel (embedded, host-gw) | CP + lnx-01 + win-01 (WS2022) | 18/18 PASS |
| B | `Run-ScenarioB.ps1` | Multus v4.3.0 on top of Flannel | CP + lnx-01 | 14/14 PASS |
| C | `Run-ScenarioC.ps1` | Cilium v1.19.4 (replaces Flannel) | CP + lnx-01 | 13/13 PASS |
| D | `Run-ScenarioD.ps1` | Calico v3.29.3 via tigera-operator (replaces Flannel) | CP + lnx-01 | 13/13 PASS |

Each scenario script: patches `config/variables.ps1`, tears down any existing cluster (keeping ISOs/cache by default), then runs all phases 0–10 end-to-end.

## Key Entry Points

| File | Purpose |
|------|---------|
| [`run-elevated.ps1`](run-elevated.ps1) | **Start here.** Elevation wrapper + log tee. |
| [`Run-ScenarioA.ps1`](Run-ScenarioA.ps1) | End-to-end: Flannel + CP + Linux + Windows worker |
| [`Run-ScenarioB.ps1`](Run-ScenarioB.ps1) | End-to-end: Multus + CP + Linux worker |
| [`Run-ScenarioC.ps1`](Run-ScenarioC.ps1) | End-to-end: Cilium + CP + Linux worker |
| [`Run-ScenarioD.ps1`](Run-ScenarioD.ps1) | End-to-end: Calico + CP + Linux worker |
| [`scripts/Main.ps1`](scripts/Main.ps1) | Orchestrator. Accepts `-StartFromPhase N`, `-ForcePhase N,M`, `-ForceNode name`, `-SkipWindowsNodes`, `-HealthCheckOnly`. |
| [`scripts/Remove-Cluster.ps1`](scripts/Remove-Cluster.ps1) | Teardown. Flags: `-All`, `-VMs`, `-Network`, `-OutputFiles`, `-Downloads`, `-KeepBaseImages`, `-Force`, `-WhatIf`. |
| [`config/variables.ps1`](config/variables.ps1) | **Single source of truth** for credentials, VM sizing, versions, node topology, CNI plugin. |
| [`check-system.ps1`](check-system.ps1) | Pre-flight check (admin, disk, Hyper-V, tools on PATH). |

## Conventions

- **All scripts require admin.** `#Requires -RunAsAdministrator` is set; use `run-elevated.ps1` or an elevated shell.
- **Phases are idempotent.** Sentinel files in `output/sentinels/` gate each phase/resource. A phase with a valid sentinel is skipped.
- **Central config.** Never hard-code credentials, VM names, versions, or paths. All live in `config/variables.ps1`.
- **Shared helpers** are in `scripts/Helpers.ps1` (logging `Write-Log`, SSH exec, `Invoke-WithRetry`, `Wait-Until`, phase read/write helpers, node enumeration helpers). Import it at the top of new scripts.
- **Packer templates** mirror `config/variables.ps1` via `-var` arguments passed in build scripts. Keep them in sync.
- **Sentinels are the idempotency mechanism.** To force a phase re-run, delete its sentinel or pass `-ForcePhase N` to `Main.ps1`.
- **`Set-StrictMode -Version Latest` is active everywhere.** Avoid `-ForegroundColor (if (...) { ... })` — PowerShell parses `if` as a command name in argument mode. Use a helper function that returns the color string instead.

## Topology Configuration (`config/variables.ps1`)

```powershell
# Control plane (always 1)
$script:ControlPlaneVMName   = 'k8s-cp-01'
$script:ControlPlaneCPU      = 2
$script:ControlPlaneRAM      = 4096   # MB

# Linux workers
$script:LinuxWorkerPrefix    = 'k8s-lnx'
$script:LinuxWorkerCount     = 1      # set to 0 for CP-only
$script:LinuxWorkerCPU       = 2
$script:LinuxWorkerRAM       = 2048   # MB

# Windows workers (set Count=0 to skip entirely)
$script:WindowsWorkerPrefix  = 'k8s-win'
$script:WindowsNodeSpecs     = @(
    @{ Count = 1; OSVersion = '2025'; CPU = 4; RAM = 7168 }
    # @{ Count = 1; OSVersion = '2022'; CPU = 4; RAM = 7168 }
)

# CNI: 'flannel' (default, required for Windows workers), 'cilium' (Linux-only), 'multus' (Linux-only), 'calico' (Linux-only), 'none'
$script:CNIPlugin            = 'flannel'
```

## Architecture

```
Windows 11 Host (Hyper-V)
├── Golden base VHDXs (read-only, built once by Packer)
│   ├── vhdx/linux-base/           — Ubuntu 24.04 + k3s binary
│   ├── vhdx/win2022-base/         — WS2022 + containerd + kubelet binary
│   └── vhdx/win2025-base/         — WS2025 + containerd + kubelet binary
│
└── Node VMs (differencing disks under vhdx/nodes/)
    ├── k8s-cp-01       (Linux control plane — k3s server)
    ├── k8s-lnx-01 ...  (Linux workers — k3s agent)
    └── k8s-win-01 ...  (Windows workers — upstream kubelet + kube-proxy)

output/kubeconfig.yaml  ← ready for kubectl after Phase 9
```

Networking: Flannel `host-gw` (no VXLAN). Pod CIDR `10.42.0.0/16`, Service CIDR `10.43.0.0/16`.
All VMs share an external vSwitch (`k8s-external`) with DHCP IPs from router.

**Cloud-init for Linux clones**: each Linux node VM gets a per-node seed ISO (volume label `CIDATA`) created with `oscdimg.exe` (Windows ADK). The seed ISO injects hostname + SSH key. The base image runs `cloud-init clean --logs --seed` so clones treat first boot as fresh.

**Windows first-boot for Windows clones**: base image contains `C:\k8s-firstboot.ps1` + a scheduled task (SYSTEM, AtStartup). `Join-Nodes.ps1` injects `C:\k8s-node-config.json` offline (via `Mount-VHD`/`Dismount-VHD`) before starting the VM. First-boot reads JSON, writes kubeconfigs, registers kubelet service with `--hostname-override`, renames computer, reboots.

## Phase Map

| # | Script | Sentinel |
|---|--------|----------|
| 0 | `Install-Prerequisites.ps1` | `phase0.done` |
| 1 | `New-HyperVSwitch.ps1` | `phase1.done` |
| 2 | `Build-LinuxBase.ps1` | `linux-base.done` |
| 3 | `Build-WindowsBase.ps1` | `win2022-base.done`, `win2025-base.done` |
| 4 | `New-LinuxNodes.ps1` | `node-k8s-cp-01.done`, `node-k8s-lnx-01.done`, … |
| 5 | `New-WindowsNodes.ps1` | `node-k8s-win-01.done`, … |
| 6 | `Bootstrap-ControlPlane.ps1` | `cp-bootstrap.done` |
| 7 | `Join-Nodes.ps1` | `node-k8s-lnx-01-ready.done`, `node-k8s-win-01-ready.done`, … |
| 8 | `Apply-CNI.ps1` | `cni.done` |
| 9 | `Export-KubeConfig.ps1` | `kubeconfig.done` |

## Script Inventory

| Script | Status | Purpose |
|--------|--------|---------|
| `Build-LinuxBase.ps1` | Working | Phase 2 — Packer build of Ubuntu base VHDX |
| `Build-WindowsBase.ps1` | Working | Phase 3 — Packer build of WS2022/WS2025 base VHDXs |
| `New-LinuxNodes.ps1` | Working | Phase 4 — Differencing disks + cloud-init seed ISOs for all Linux nodes |
| `New-WindowsNodes.ps1` | Working | Phase 5 — Differencing disks for all Windows nodes (not started) |
| `Bootstrap-ControlPlane.ps1` | Working | Phase 6 — Configure k3s server on CP, export node-token + kubeconfig |
| `Join-Nodes.ps1` | Working | Phase 7 — Join Linux workers (SSH) and Windows workers (Mount-VHD + VMBus) |
| `Apply-CNI.ps1` | Working | Phase 8 — Apply CNI manifests (no-op for flannel, DaemonSet for multus, Helm for cilium/calico) |
| `Export-KubeConfig.ps1` | Working | Phase 9 — Write output/kubeconfig.yaml + cluster-info.txt |
| `Verify-Cluster.ps1` | Working | Phase 10 — Cross-node pod connectivity, DNS, ClusterIP service, Windows node checks, CNI health per plugin |
| `Install-Prerequisites.ps1` | Working | Phase 0 — Installs tools including Windows ADK (oscdimg) |
| `Remove-Cluster.ps1` | Working | Teardown — iterates all nodes, removes vhdx/nodes/ |
| `Main.ps1` | Working | 10-phase orchestrator; handles Cilium/Calico pre-join phase ordering |
| `Helpers.ps1` | Working | Get-AllLinuxNodeNames, Get-AllWindowsNodeNames, New-DifferencingNode, New-SeedISO, Send-SshFile, etc. |
| `Build-LinuxVM.ps1` | Legacy | Superseded (kept for reference) |
| `Build-WindowsVM.ps1` | Legacy | Superseded (kept for reference) |
| `Join-WindowsNode.ps1` | Legacy | Superseded (kept for reference) |

## Packer Templates

| File | Purpose |
|------|---------|
| `packer/linux/ubuntu.pkr.hcl` | Ubuntu base — runs 01-base.sh, 02-install-k3s-binary.sh, 03-cloud-init-clean.sh |
| `packer/linux/scripts/02-install-k3s-binary.sh` | Installs k3s binary only (no systemd unit) |
| `packer/linux/scripts/03-cloud-init-clean.sh` | cloud-init clean + machine-id truncate |
| `packer/windows/winserver.pkr.hcl` | Windows base — uses `os_version` var + `floppy_dirs` |
| `packer/windows/autounattend/2022/autounattend.xml` | WS2022 answer file |
| `packer/windows/autounattend/2025/autounattend.xml` | WS2025 answer file |
| `packer/windows/scripts/04-install-k8s-binaries.ps1` | Installs binaries + static config (no kubeconfigs, no kubelet svc) |
| `packer/windows/scripts/05-firstboot-setup.ps1` | Creates k8s-firstboot.ps1 template + scheduled task |

## CNI Config Files

| File | Purpose |
|------|---------|
| `config/cni/multus-daemonset.yaml` | Multus v4.3.0 thick DaemonSet (`ghcr.io/k8snetworkplumbingwg/multus-cni:v4.3.0-thick`) |
| `config/cni/cilium-values.yaml` | Cilium v1.19.4 Helm values (native routing, IPAM=kubernetes, k3s CNI paths) |
| `config/cni/calico-values.yaml` | Calico v3.29.3 tigera-operator Helm values (VXLAN, BGP disabled, pod CIDR 10.42.0.0/16) |

## Common Tasks

**Verify cluster (run tests only)**: `$env:KUBECONFIG="output/kubeconfig.yaml"; kubectl get nodes -o wide`

**Re-run verification**: `.\scripts\Verify-Cluster.ps1 -Force`

**Verify health only (no pod deploy)**: `.\scripts\Verify-Cluster.ps1 -HealthOnly`

**Re-run a failed phase**: `.\scripts\Main.ps1 -StartFromPhase 4`

**Force specific phases**: `.\scripts\Main.ps1 -ForcePhase 2,3`

**Force a single node re-join**: `.\scripts\Main.ps1 -ForceNode k8s-win-01`

**Linux-only cluster** (no Windows): set `$script:WindowsNodeSpecs = @()` in `config/variables.ps1`

**Skip Windows at runtime**: `.\scripts\Main.ps1 -SkipWindowsNodes`

**Full rebuild**: `.\scripts\Remove-Cluster.ps1 -All` then `.\run-elevated.ps1`

**Dry-run delete**: `.\scripts\Remove-Cluster.ps1 -All -WhatIf`

## Pitfalls

- Phase 0 may trigger a reboot (Hyper-V install). Re-run after reboot — sentinels preserve progress.
- **Rebuild SSH key mismatch**: `-OutputFiles` deletes `output/linux-build-key*`. On the next run a new key pair is generated. `Build-LinuxBase.ps1` detects this and overwrites the old key in `packer/linux/http/user-data` automatically (regex replaces `ssh-ed25519 … packer-linux-build` lines). Keep the `packer-linux-build` comment suffix on key lines so the replacement works.
- `$script:HostNicName` auto-detects via default route; override in `config/variables.ps1` if the wrong NIC is selected.
- Windows VM base build takes 15–25 min (feature install requires in-guest reboots during Packer).
- Containerd is pinned to **v1.7.32** — v2.x breaks the CRI v1 API that kubelet (via k3s) expects.
- **Cilium and Calico require pre-join CNI phase ordering**: these CNIs replace flannel (`--flannel-backend=none`), so nodes stay `NotReady` until the CNI is applied. `Main.ps1` runs `Apply-CNI.ps1` before `Join-Nodes.ps1` automatically when `CNIPlugin -in @('cilium', 'calico')`. Windows workers are incompatible with Cilium and Calico — use `CNIPlugin = 'flannel'` for Scenario A.
- **Helm is required** for Cilium and Calico installs. Phase 0 checks for it on PATH. Install: `winget install --id Helm.Helm`.
- **Windows VM first-boot auto-reboot**: after VM start, `k8s-firstboot.ps1` renames the computer and reboots. `Join-Nodes.ps1` detects this via VMBus PSSession retry loop and waits for the second boot automatically.
- **oscdimg.exe** is required for Linux cloud-init seed ISOs. Phase 0 installs Windows ADK via winget if missing.
- Base VHDXs must remain read-only after creation (set in Build-LinuxBase.ps1 / Build-WindowsBase.ps1). If you need to rebuild a base, delete its sentinel and re-run.
- The kubeconfig server address is patched in **Phase 9** (`Export-KubeConfig.ps1`). Don't use the raw kubeconfig from the VM.

## See Also

- [README.md](README.md) — user-facing setup and usage guide
- [docs/architecture.md](docs/architecture.md) — component layout, networking internals, build sequence
- [docs/plan-multiNodeK3sCluster.prompt.md](docs/plan-multiNodeK3sCluster.prompt.md) — architecture decisions for the multi-node design
