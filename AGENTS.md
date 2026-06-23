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
| A | `Run-ScenarioA.ps1` | Flannel (embedded, host-gw) | CP + lnx-01 + lnx-02 + win-01 (WS2022) | PASS (04:38) |
| B | `Run-ScenarioB.ps1` | Multus v4.3.0 on top of Flannel | CP + lnx-01 + lnx-02 | PASS (04:22) |
| C | `Run-ScenarioC.ps1` | Cilium v1.19.5 + Hubble (replaces Flannel) | CP + lnx-01 + lnx-02 | 28/28 PASS (06:39) |
| D | `Run-ScenarioD.ps1` | Calico v3.32.0 via tigera-operator (replaces Flannel) | CP + lnx-01 + lnx-02 | 28/28 PASS (05:12) |
| E | `Run-ScenarioE.ps1` | Flannel (host-gw) + chained Cilium + Hubble (Linux only) | CP + lnx-01 + lnx-02 + win-01 (WS2022) | 38/38 PASS (06:35) |
| F | `Run-ScenarioF.ps1` | Antrea v2.6.2 (OVS, unified Linux + Windows, VXLAN) | CP + lnx-01 + lnx-02 + win-01 (WS2022) | PASS (43/43) |

Each scenario script: patches `config/variables.ps1`, tears down any existing cluster (keeping ISOs/cache by default), then runs all phases 0–10 end-to-end.
All scenarios default to **2 Linux workers** (`lnx-01` + `lnx-02`). Pass `-NoExtraWorker` to each script to use only 1.
Use `Run-AllScenarios.ps1` to run all six scenarios in sequence.

## Key Entry Points

| File | Purpose |
|------|---------|
| [`run-elevated.ps1`](run-elevated.ps1) | **Start here.** Elevation wrapper + log tee. |
| [`Run-ScenarioA.ps1`](Run-ScenarioA.ps1) | End-to-end: Flannel + CP + Linux + Windows worker |
| [`Run-ScenarioB.ps1`](Run-ScenarioB.ps1) | End-to-end: Multus + CP + Linux worker |
| [`Run-ScenarioC.ps1`](Run-ScenarioC.ps1) | End-to-end: Cilium + CP + Linux worker |
| [`Run-ScenarioD.ps1`](Run-ScenarioD.ps1) | End-to-end: Calico + CP + Linux worker |
| [`Run-ScenarioE.ps1`](Run-ScenarioE.ps1) | End-to-end: Flannel + chained Cilium + CP + Linux + Windows worker |
| [`Run-ScenarioF.ps1`](Run-ScenarioF.ps1) | End-to-end: Antrea (OVS) + CP + Linux + Windows worker |
| [`scripts/Main.ps1`](scripts/Main.ps1) | Orchestrator. Accepts `-StartFromPhase N`, `-ForcePhase N,M`, `-ForceNode name`, `-SkipWindowsNodes`, `-HealthCheckOnly`. |
| [`scripts/Remove-Cluster.ps1`](scripts/Remove-Cluster.ps1) | Teardown. Flags: `-All`, `-VMs`, `-Network`, `-OutputFiles`, `-Downloads`, `-KeepBaseImages`, `-Force`, `-WhatIf`. |
| [`config/variables.ps1`](config/variables.ps1) | **Single source of truth** for credentials, VM sizing, versions, node topology, CNI plugin. |
| [`check-system.ps1`](check-system.ps1) | Pre-flight check (admin, disk, Hyper-V, tools on PATH). |
| [`Scale-LinuxWorkers.ps1`](Scale-LinuxWorkers.ps1) | Scale Linux workers up/down post-cluster. Accepts `-TargetCount N`, `-DrainTimeoutSec`, `-NodeDeleteTimeoutSec`, `-WhatIf`. |

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

# CNI: 'flannel' (default, required for Windows workers), 'flannel+cilium' (Flannel + chained Cilium, supports Windows),
#      'cilium' (Linux-only), 'multus' (Linux-only), 'calico' (Linux-only), 'antrea' (Linux + Windows, OVS), 'none'
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
| `Apply-CNI.ps1` | Working | Phase 8 — Apply CNI manifests (no-op for flannel, DaemonSet for multus, Helm for cilium/calico/flannel+cilium/antrea) |
| `Export-KubeConfig.ps1` | Working | Phase 9 — Write output/kubeconfig.yaml + cluster-info.txt |
| `Verify-Cluster.ps1` | Working | Phase 10 — Cross-node pod connectivity, DNS, ClusterIP service, Hubble flow observability (Cilium scenarios), Windows node checks, CNI health per plugin |
| `Install-Prerequisites.ps1` | Working | Phase 0 — Installs tools including Windows ADK (oscdimg) and Helm |
| `Remove-Cluster.ps1` | Working | Teardown — iterates all nodes, removes vhdx/nodes/ |
| `Main.ps1` | Working | 10-phase orchestrator; handles Cilium/Calico/Antrea/flannel+cilium pre-join phase ordering |
| `Helpers.ps1` | Working | Get-AllLinuxNodeNames, Get-AllWindowsNodeNames, New-DifferencingNode, New-SeedISO, Send-SshFile, etc. |
| `Run-AllScenarios.ps1` | Working | Runs all (or a subset of) scenarios A–F end-to-end; accepts `-Scenarios`, `-NoExtraWorker`, `-DeleteGoldenImages`, `-CleanupAfterAll` |
| `Run-ScenarioE.ps1` | Working | End-to-end: Flannel + chained Cilium + CP + Linux + Windows worker |
| `Run-ScenarioF.ps1` | Working | End-to-end: Antrea OVS + CP + Linux + Windows worker (WS2022) |
| `Build-LinuxVM.ps1` | Legacy | Superseded (kept for reference) |
| `Build-WindowsVM.ps1` | Legacy | Superseded (kept for reference) |
| `Join-WindowsNode.ps1` | Legacy | Superseded (kept for reference) |
| `Update-KubeConfig.ps1` | Working | Patches `output/kubeconfig.yaml` with current control-plane VM IP, and updates `K3S_URL` + restarts `k3s-agent` on all Linux workers, after a network change |
| `Scale-LinuxWorkers.ps1` | Working | Post-cluster scaling — scale-up creates new VMs + joins them; scale-down drains, deletes node object, stops k3s-agent, removes VM + VHDX + seed ISO + sentinels; patches `$script:LinuxWorkerCount` in `config/variables.ps1` after each node |
| `Test-ScaleLinuxWorkers.ps1` | Working | End-to-end test for `Scale-LinuxWorkers.ps1` — runs fixed sequence (0→4→3→1), asserts 6 invariants per step (kubectl nodes, Hyper-V VMs, variables.ps1, sentinels, VHDXs, seed ISOs), restores original count after run |

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
| `config/cni/cilium-values.yaml` | Cilium v1.19.5 Helm values (native routing, IPAM=kubernetes, k3s CNI paths, **Hubble relay+UI enabled**) |
| `config/cni/cilium-chained-values.yaml` | Cilium v1.19.5 Helm values for **generic-veth chaining mode** (Scenario E — layered on top of Flannel; Hubble relay+UI enabled, Linux-only nodeSelector) |
| `config/cni/calico-values.yaml` | Calico v3.29.3 tigera-operator Helm values (VXLAN, BGP disabled, pod CIDR 10.42.0.0/16) |
| `config/cni/antrea-values.yaml` | Antrea v2.6.2 Helm values (VXLAN tunnel, Linux agent nodeSelector, antreaProxy health-check server disabled) |

## Common Tasks

**Refresh kubeconfig after changing networks** (home ↔ office — VM IP changes with DHCP): `.\Update-KubeConfig.ps1`
This patches `output/kubeconfig.yaml` **and** SSHes into each Linux worker to update `K3S_URL` + restart `k3s-agent`, so nodes return to `Ready`.

**Verify cluster (run tests only)**: `$env:KUBECONFIG="output/kubeconfig.yaml"; kubectl get nodes -o wide`

**Re-run verification**: `.\scripts\Verify-Cluster.ps1 -Force`

**Verify health only (no pod deploy)**: `.\scripts\Verify-Cluster.ps1 -HealthOnly`

**Re-run a failed phase**: `.\scripts\Main.ps1 -StartFromPhase 4`

**Force specific phases**: `.\scripts\Main.ps1 -ForcePhase 2,3`

**Force a single node re-join**: `.\scripts\Main.ps1 -ForceNode k8s-win-01`

**Linux-only cluster** (no Windows): set `$script:WindowsNodeSpecs = @()` in `config/variables.ps1`

**Skip Windows at runtime**: `.\scripts\Main.ps1 -SkipWindowsNodes`

**Full rebuild**: `.\scripts\Remove-Cluster.ps1 -All` then `.\run-elevated.ps1`

**Run all scenarios (force Packer rebuild after version bump)**: `.\Run-AllScenarios.ps1 -DeleteGoldenImages`
Deletes golden base VHDXs before the first scenario so Packer rebuilds them with the updated k3s/containerd versions. Subsequent scenarios reuse the rebuilt images.

**Dry-run delete**: `.\scripts\Remove-Cluster.ps1 -All -WhatIf`

**Scale Linux workers up**: `.\Scale-LinuxWorkers.ps1 -TargetCount 3`
Adds nodes starting from the next index; creates VMs + joins them. Patches `$script:LinuxWorkerCount` in `config/variables.ps1`.

**Scale Linux workers down**: `.\Scale-LinuxWorkers.ps1 -TargetCount 1`
Removes nodes from the highest index first; drains workloads, deletes the node object, stops k3s-agent, removes VM + VHDX + seed ISO, clears sentinels. Patches `config/variables.ps1` after each node. Use `-DrainTimeoutSec 0` to force-drain (skips PDB checks). Use `-WhatIf` to preview.

**Test scaling end-to-end**: `.\Test-ScaleLinuxWorkers.ps1`
Runs the full sequence (0→4→3 force→1), asserts 6 invariants per step, then restores the original worker count. Use `-SkipRestore` to leave at count=1.

## Pitfalls

- Phase 0 may trigger a reboot (Hyper-V install). Re-run after reboot — sentinels preserve progress.
- **Rebuild SSH key mismatch**: `-OutputFiles` deletes `output/linux-build-key*`. On the next run a new key pair is generated. `Build-LinuxBase.ps1` detects this and overwrites the old key in `packer/linux/http/user-data` automatically (regex replaces `ssh-ed25519 … packer-linux-build` lines). Keep the `packer-linux-build` comment suffix on key lines so the replacement works.
- `$script:HostNicName` auto-detects via default route; override in `config/variables.ps1` if the wrong NIC is selected.
- Windows VM base build takes 15–25 min (feature install requires in-guest reboots during Packer).
- Containerd is pinned to **v1.7.33** (latest 1.7.x) — v2.x breaks the CRI v1 API that kubelet (via k3s) expects on Windows workers.
- **Cilium, Calico, and flannel+cilium require pre-join or post-join phase ordering**: For `cilium` and `calico`, nodes stay `NotReady` until the CNI is applied — `Main.ps1` runs `Apply-CNI.ps1` *before* `Join-Nodes.ps1`. For `flannel+cilium`, Flannel handles routing so all nodes (including Windows) join first, then Cilium is chained in post-join. `Main.ps1` handles this ordering automatically for all three.
- **Helm is required** for Cilium, Calico, and flannel+cilium installs. Phase 0 checks for it on PATH. Install: `winget install --id Helm.Helm`.
- **Hubble observability**: Hubble is enabled in Scenarios C and E (relay + UI deployments in `kube-system`). `Verify-Cluster.ps1` validates Hubble relay/UI readiness and uses `kubectl exec` into a Cilium pod to run `hubble observe` — no host-side tooling is required. The `hubble` binary is baked into the Cilium container image.
- **Windows VM first-boot auto-reboot**: after VM start, `k8s-firstboot.ps1` renames the computer and reboots. `Join-Nodes.ps1` detects this via VMBus PSSession retry loop and waits for the second boot automatically.
- **oscdimg.exe** is required for Linux cloud-init seed ISOs. Phase 0 installs Windows ADK via winget if missing.
- Base VHDXs must remain read-only after creation (set in Build-LinuxBase.ps1 / Build-WindowsBase.ps1). If you need to rebuild a base, delete its sentinel and re-run.
- The kubeconfig server address is patched in **Phase 9** (`Export-KubeConfig.ps1`). Don't use the raw kubeconfig from the VM.
- **Packer `execute_command` must include `env {{.Vars}}`** for shell provisioners running under `sudo`. Plain `sudo -S bash {{.Path}}` silently drops all `environment_vars` (sudo strips env by default). The correct form is `echo '...' | sudo -S env {{.Vars}} bash {{.Path}}`. Without this, k3s version env vars are ignored and the golden image always uses the hardcoded script default.
- **Kubelet removed flags for k8s 1.31+ and 1.33+**: `--pod-infra-container-image` was removed in k8s 1.31 — set it in `KubeletConfiguration.podInfraContainerImage` instead. `--cloud-provider` was removed in k8s 1.33 — omit it entirely. Both flags cause kubelet to exit immediately with "unknown flag", preventing the kubelet service from ever reaching Running state.
- **Calico 3.30+ two-phase Helm install**: the tigera-operator chart registers CRDs via the operator pod itself. Helm validates resources against the API schema before applying them, so a single `helm install` fails with "no matches for kind X". Fix: install the operator first with all CRs disabled (`--set installation.enabled=false` etc.), wait for the operator pod to start (which registers the CRDs), then `helm upgrade` with the full values file. `Apply-CNI.ps1` handles this automatically.
- **Antrea TESTSIGNING requirement**: The OVS kernel driver shipped in `antrea-windows-with-ovs.yml` is test-signed. Windows nodes must have `bcdedit /set TESTSIGNING ON` active. The firstboot script (`05-firstboot-setup.ps1`) sets this automatically when `cniPlugin=antrea` in `k8s-node-config.json`, and it takes effect on the rename/reboot that follows.
- **Antrea PrepareAntreaAgent startup task**: Registered by the firstboot script for Antrea nodes. Runs at every boot (not just first boot) to clean stale OVS bridge / HNS networks before the antrea-agent HostProcess Container starts. Uses `-RunOVSServices $false` because OVS runs containerized inside the HPC pod.
- **Antrea CNI binary path mismatch**: `install-cni` puts `antrea.exe` in `C:\opt\cni\bin\` but containerd's `bin_dir = "C:\k\cni"` (set in `C:\containerd\config\config.toml`). The `fix-cni-config` init container (injected by `Apply-CNI.ps1`) copies `antrea.exe` to `C:\k\cni\` after `install-cni` runs. The `FixAntreaCniPath` AtStartup task does the same on subsequent boots.
- **Antrea Windows OVS driver install is slow**: The containerized OVS driver installation inside the HostProcess Container can take 1–3 minutes on first boot. `Apply-CNI.ps1` waits up to 600 s for the antrea-agent-windows pod to reach Running state. Do not interrupt the first boot.
- **Antrea transportInterface must be physical adapter**: When OVS creates the Transparent HNS network, the node IP migrates from `Ethernet 2` to `vEthernet (Ethernet 2)`. antrea-agent must be told to use the physical adapter explicitly via `transportInterface: Ethernet 2` in the `antrea-windows-config` ConfigMap. Apply-CNI.ps1 patches this automatically via a multiline-safe regex (`(?m)^\s*#?\s*transportInterface:.*$`).
- **Antrea containerd CNI path mismatch**: containerd reads CNI config from `C:\k\cni\config` (set in `C:\containerd\config\config.toml`), NOT from `C:\etc\cni\net.d` (where the Antrea `install-cni` init container writes). After firstboot, the stale Flannel `10-flannel.conflist` (sdnbridge plugin) remains in `C:\k\cni\config` and takes precedence. Fix: the `fix-cni-config` init container (injected by Apply-CNI.ps1 after `install-cni`) removes the Flannel config and copies the Antrea config without BOM to `C:\k\cni\config`, then restarts containerd. The `FixAntreaCniPath` AtStartup task (registered by firstboot patching) handles this for subsequent boots.
- **Antrea Hyper-V PowerShell module required**: antrea-agent on Windows calls `Get-VMNetworkAdapter` (in the Hyper-V PS module) to discover the vNIC MAC address after OVS creates the Transparent HNS bridge. `Microsoft-Hyper-V-Management-PowerShell` is disabled by default on Hyper-V Gen 1 guests. The firstboot patch enables `RSAT-Hyper-V-Tools-Feature` + `Microsoft-Hyper-V-Management-PowerShell` via `Enable-WindowsOptionalFeature`.
- **Antrea prepare-network init container**: The `antrea-agent-windows` DaemonSet gets a `prepare-network` init container injected by Apply-CNI.ps1 that removes stale HNS networks (`antrea-hnsnetwork`, `cbr0`, `vxlan0`) before each pod restart. Without this, antrea-agent crashes on restart because the previous run's Transparent HNS network keeps the IP on `vEthernet (Ethernet 2)` instead of `Ethernet 2`.
- **PS5.1 em dash encoding in Packer scripts**: Packer runs Windows provisioner scripts via `powershell.exe` (PS 5.1), not `pwsh`. Source files without a UTF-8 BOM are read as Windows-1252. An em dash `—` stored as UTF-8 bytes `0xE2 0x80 0x94` is decoded as `â€"` (three Windows-1252 chars), where `0x94` = U+201D RIGHT DOUBLE QUOTATION MARK, which PowerShell treats as a closing `"` inside double-quoted strings. This silently breaks string literals in any generated script and causes parse failures at runtime. **Rule**: Use ASCII hyphen `-` (not em dash) in double-quoted strings inside any Packer provisioner script.
- **`grep -c 'Ready'` matches `NotReady`**: `grep -c 'Ready'` counts every line containing the substring "Ready", including lines with status `NotReady`. Use `awk '$2=="Ready"{c++} END{print c+0}'` for exact status-column matching. The `|| echo '0'` fallback on a failed grep also produces a two-line string (`0\n0`) that breaks integer comparisons in `[ "$n" -ge 1 ]`. The awk form always emits a clean integer.

## See Also

- [README.md](README.md) — user-facing setup and usage guide
- [docs/architecture.md](docs/architecture.md) — component layout, networking internals, build sequence
- [docs/plan-multiNodeK3sCluster.prompt.md](docs/plan-multiNodeK3sCluster.prompt.md) — architecture decisions for the multi-node design
