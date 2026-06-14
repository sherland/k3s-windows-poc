# Copilot Instructions — Hyper-V k3s Cluster

This repo automates building a two-node k3s cluster (Ubuntu Linux master + Windows Server worker) on a Windows 11 Hyper-V host using Packer.

## Key Entry Points

| File | Purpose |
|------|---------|
| [`run-elevated.ps1`](run-elevated.ps1) | **Start here.** Elevation wrapper + log tee. |
| [`scripts/Main.ps1`](scripts/Main.ps1) | Orchestrator. Accepts `-StartFromPhase N`, `-ForcePhase N,M`, `-HealthCheckOnly`. |
| [`scripts/Remove-Cluster.ps1`](scripts/Remove-Cluster.ps1) | Teardown. Flags: `-All`, `-VMs`, `-Network`, `-OutputFiles`, `-Downloads`, `-WhatIf`. |
| [`config/variables.ps1`](config/variables.ps1) | **Single source of truth** for credentials, VM sizing, versions, timeouts, NIC name. |
| [`check-system.ps1`](check-system.ps1) | Pre-flight check (admin, disk, Hyper-V, tools on PATH). |

## Conventions

- **All scripts require admin.** `#Requires -RunAsAdministrator` is set; use `run-elevated.ps1` or an elevated shell.
- **Phases are idempotent.** Sentinel files in `output/sentinels/phase-phaseN.done` gate each phase. A phase that has a sentinel is skipped.
- **Central config.** Never hard-code credentials, VM names, versions, or paths. All live in `config/variables.ps1`.
- **Shared helpers** are in `scripts/Helpers.ps1` (logging `Write-Log`, SSH exec, `Invoke-WithRetry`, `Wait-Until`, phase read/write helpers). Import it at the top of new scripts.
- **Packer templates** mirror `config/variables.ps1` via `-var` arguments passed in the build scripts. Keep them in sync.
- **Sentinels are the idempotency mechanism.** To force a phase re-run, delete its sentinel or pass `-ForcePhase N` to `Main.ps1`.
- **`Set-StrictMode -Version Latest` is active everywhere.** Avoid `-ForegroundColor (if (...) { ... })` — PowerShell parses `if` as a command name in argument mode. Use a helper function that returns the color string instead.

## Architecture

```
Windows 11 Host (Hyper-V)
├── k8s-linux-master   (Ubuntu 24.04)              → k3s SERVER, 2 CPU / 4 GB
└── k8s-windows-worker (Windows Server 2022 Eval)  → k3s AGENT,  4 CPU / 7 GB
Both VMs on external vSwitch (k8s-external) — DHCP IPs from router
output/kubeconfig.yaml ← ready for kubectl after Phase 5
```

Networking: Flannel `host-gw` (no VXLAN). Pod CIDR `10.42.0.0/16`, Service CIDR `10.43.0.0/16`.

**Name split**: `$script:WindowsVMName = 'k8s-windows-worker'` (Hyper-V VM name) vs `$script:WindowsNodeName = 'k8s-win-worker'` (Windows hostname / Kubernetes node name, ≤15 chars). Always use `$script:WindowsNodeName` when calling `kubectl get node`.

## Phase Map

| # | Script | Sentinel |
|---|--------|----------|
| 0 | `Install-Prerequisites.ps1` | Tools + Hyper-V present |
| 1 | `New-HyperVSwitch.ps1` | vSwitch exists as External |
| 2 | `Build-LinuxVM.ps1` | Linux VM running, k3s active |
| 3 | `Build-WindowsVM.ps1` (ISO download part) | ISO > 1 GB |
| 4 | `Build-WindowsVM.ps1` (Packer build part) | Windows VM running, k3s agent active |
| 5 | `Export-KubeConfig.ps1` | `output/kubeconfig.yaml` valid |
| 6 | `Join-WindowsNode.ps1` | Both nodes Ready in kubectl |

## Common Tasks

**Verify cluster**: `$env:KUBECONFIG="output/kubeconfig.yaml"; kubectl get nodes -o wide`

**Re-run a failed phase**: `.\scripts\Main.ps1 -StartFromPhase 4`

**Force specific phases**: `.\scripts\Main.ps1 -ForcePhase 2,4`

**Full rebuild**: `.\scripts\Remove-Cluster.ps1 -All` then `.\run-elevated.ps1`

**Dry-run delete**: `.\scripts\Remove-Cluster.ps1 -All -WhatIf`

## Pitfalls

- Phase 0 may trigger a reboot (Hyper-V install). Re-run after reboot — sentinels preserve progress.
- **Rebuild SSH key mismatch**: `-OutputFiles` deletes `output/linux-build-key*`. On the next run a new key pair is generated. `Build-LinuxVM.ps1` detects this and overwrites the old key in `packer/linux/http/user-data` automatically (regex replaces `ssh-ed25519 … packer-linux-build` lines). If you edit `user-data` manually, keep the `packer-linux-build` comment suffix on key lines so the replacement works.
- `$script:HostNicName` auto-detects via default route; override in `config/variables.ps1` if the wrong NIC is selected. Phase 1 has a 30 s retry loop for the case where the route table is transiently absent after vSwitch teardown.
- Windows VM build takes 15–25 min (feature install requires in-guest reboots during Packer).
- Containerd on Windows is pinned to v1.x (`1.7.32`) — v2.x breaks the CRI v1 API that k3s agent expects.
- **Windows VM auto-reboot in Phase 6**: On first boot after Packer export, the Windows VM may shut itself Off once to complete deferred setup (feature installation, etc.). `Join-WindowsNode.ps1` detects this and calls `Start-VM` automatically — this is expected and handled. Total Phase 6 timeout is 5 min (register) + 10 min (Ready).
- **VMs Off after cluster completes**: The health check run at the end of `Main.ps1` may see both VMs as `Off` if the Windows VM's post-Packer reboot is still in progress. The cluster is functional; re-run `Main.ps1 -HealthCheckOnly` after ~2 min. Sentinels are already set so no phases re-run.
- The kubeconfig server address is patched in **Phase 5** (`Export-KubeConfig.ps1`); don't use the raw `/etc/rancher/k3s/k3s.yaml` from the VM.

## See Also

- [README.md](README.md) — user-facing setup and usage guide
- [docs/architecture.md](docs/architecture.md) — component layout, networking internals, build sequence, file inventory
- [docs/plan-k8sHyperVCluster.prompt.md](docs/plan-k8sHyperVCluster.prompt.md) — architecture decisions and design rationale
