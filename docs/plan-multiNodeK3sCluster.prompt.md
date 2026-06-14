# Plan: Multi-Node Configurable k3s Cluster

## Decisions

- Single control-plane only (no HA/etcd clustering)
- CNI as post-bootstrap config variable (flannel default, cilium/multus later)
- Linux: Hyper-V differencing disks from golden base VHDX (layered, cloud-init re-seed per node)
- Windows: also differencing disks from per-OS-version base VHDX (WS2022 and/or WS2025)
- Per-Windows-node OS version configurable (can mix 2022 and 2025 in same cluster)
- Windows node count can be 0

---

## Architecture: VM Hierarchy (Differencing Disks)

Hyper-V's **differencing disk** is exactly what you had in mind — it's the Hyper-V equivalent of a container image layer. A child VHDX stores only delta blocks from a read-only parent. Creating one takes seconds and uses near-zero disk. Multiple nodes can share one parent.

```
Linux Base VHDX  (Packer, ~15 min, ~4 GB)
  └── k8s-cp-01.vhdx     (differencing, seconds, ~50 MB delta)
  └── k8s-lnx-01.vhdx    (differencing)
  └── k8s-lnx-02.vhdx    (differencing)

WS2022 Base VHDX  (Packer, ~20 min)
  └── k8s-win2022-01.vhdx  (differencing)

WS2025 Base VHDX  (Packer, ~20 min)
  └── k8s-win2025-01.vhdx  (differencing)
  └── k8s-win2025-02.vhdx  (differencing)
```

Per-node identity is injected at first boot via a **cloud-init NoCloud seed ISO** (Linux) or a **first-boot startup script** (Windows, no sysprep), not baked into the base image.

---

## Phase Map (Restructured)

| # | Script | What it does | Sentinel |
|---|--------|-------------|----------|
| 0 | `Install-Prerequisites.ps1` | Tools + Hyper-V | existing |
| 1 | `New-HyperVSwitch.ps1` | vSwitch | existing |
| **2** | **`Build-LinuxBase.ps1`** | Packer → Ubuntu golden VHDX. Includes: k3s binary, containerd, crictl, common tools. Ends with `cloud-init clean` so re-seed works. No role configured. | `linux-base.done` |
| **3** | **`Build-WindowsBase.ps1`** | For each needed OS version: Packer → WS2022/WS2025 golden VHDX. Installs Containers feature, containerd, k3s agent binary. Ends with a "generalize" startup script reset. | `win2022-base.done`, `win2025-base.done` |
| **4** | **`New-LinuxNodes.ps1`** | For each Linux node in spec: create differencing disk, generate cloud-init seed ISO (hostname, role=server\|agent, SSH key, k3s version), create + start Hyper-V VM. | `node-{name}.done` per node |
| **5** | **`New-WindowsNodes.ps1`** | Same pattern for Windows nodes, keyed on OS version to pick parent VHDX. Per-node first-boot script handles hostname + k3s join token. Skipped entirely if 0 Windows nodes. | `node-{name}.done` per node |
| **6** | **`Bootstrap-ControlPlane.ps1`** | Wait for CP VM ready. Run k3s server init (via SSH). Retrieve node-token. Create RBAC resources (flannel SA, CSR auto-approver). | `cp-bootstrap.done` |
| **7** | **`Join-Nodes.ps1`** | For each worker (Linux + Windows): wait for it to register + become Ready. Label nodes. Handles post-setup reboots. | `node-{name}-ready.done` per node |
| **8** | **`Apply-CNI.ps1`** | If CNI != 'flannel' (default embedded): apply manifests. For cilium: helm install. For multus: apply DaemonSet. No-op if flannel. | `cni.done` |
| **9** | **`Export-KubeConfig.ps1`** | Existing logic, uses control-plane IP. Rename context from "k8s-hyper-v" to cluster name variable. | existing |

Phases 2 and 3 can run **in parallel** (Linux and Windows base builds are independent). Phases 4 and 5 can run **in parallel** after their respective base phases.

---

## `config/variables.ps1` Changes

Add a **cluster topology spec** replacing all hardcoded single-VM names:

```powershell
# --- Cluster Topology ---
$script:ControlPlaneCPU  = 2
$script:ControlPlaneRAM  = 4096

$script:LinuxWorkerCount = 1     # 0 = control-plane only
$script:LinuxWorkerCPU   = 2
$script:LinuxWorkerRAM   = 4096

# Per-entry: Count + OS version ('2022' | '2025') + optional sizing
$script:WindowsNodeSpecs = @(
    @{ Count = 1; OSVersion = '2022'; CPU = 4; RAM = 7168 },
    @{ Count = 2; OSVersion = '2025'; CPU = 4; RAM = 7168 }
)
# Set to @() for zero Windows nodes

# --- CNI ---
$script:CNIPlugin       = 'flannel'    # 'flannel' | 'cilium' | 'none'
$script:FlannelBackend  = 'host-gw'   # 'host-gw' | 'vxlan'

# --- Naming ---
$script:ControlPlaneVMName  = 'k8s-cp-01'      # ≤15 chars for Windows compat
$script:LinuxWorkerPrefix   = 'k8s-lnx'        # → k8s-lnx-01, k8s-lnx-02
$script:WindowsWorkerPrefix = 'k8s-win'        # → k8s-win-01, k8s-win-02
```

Derived names (generated at runtime, not stored in config):
- Linux worker names: `"$LinuxWorkerPrefix-{01..N}"`
- Windows worker names: `"$WindowsWorkerPrefix-{01..M}"` — sorted by spec order, so `win-01` = first spec entry

---

## Key File Changes

**Files to modify:**
- `config/variables.ps1` — Replace single-VM vars with topology spec above
- `scripts/Main.ps1` — Remap phase numbers, add parallel phase dispatch, update health check to iterate all nodes
- `scripts/Helpers.ps1` — Add `New-DifferencingNode` helper (create differencing VHDX + Hyper-V VM), `New-SeedISO` helper (generate cloud-init NoCloud ISO), per-VM sentinel helpers
- `packer/linux/ubuntu.pkr.hcl` + `packer/linux/scripts/02-k3s-server.sh` — Remove k3s server init from Packer; install binary only; add `cloud-init clean` shutdown step
- `packer/windows/winserver.pkr.hcl` — Parameterize OS version (iso_path + checksum). Add first-boot script reset mechanism instead of sysprep.

**Files to create:**
- `scripts/Build-LinuxBase.ps1` — Replaces `Build-LinuxVM.ps1`
- `scripts/Build-WindowsBase.ps1` — Replaces `Build-WindowsVM.ps1` (multi-version aware)
- `scripts/New-LinuxNodes.ps1` — Differencing disk clones + cloud-init seed ISOs
- `scripts/New-WindowsNodes.ps1` — Differencing disk clones + first-boot scripts
- `scripts/Bootstrap-ControlPlane.ps1` — k3s server init (extracted from old Build-LinuxVM.ps1)
- `scripts/Join-Nodes.ps1` — Replaces `Join-WindowsNode.ps1`, iterates all nodes
- `scripts/Apply-CNI.ps1` — CNI manifest dispatch (no-op for flannel, helm for cilium)
- `packer/linux/scripts/00-binary-install.sh` — Install k3s binary + containerd, NO server init
- `packer/windows/scripts/00-generalize.ps1` — Reset first-boot script trigger before Packer shutdown
- `config/cni/flannel.yaml`, `config/cni/cilium-values.yaml` — CNI config templates

---

## Cloud-init Re-seed Strategy (Linux nodes)

The key to the differencing disk clone working with cloud-init:

1. **Base Packer build ends with**: `cloud-init clean --logs --seed` — this wipes cloud-init state so the next boot treats it as a fresh instance.
2. **Per-node seed ISO** (generated by `New-SeedISO` helper) contains:
   - `meta-data`: `instance-id: <uuid>`, `local-hostname: <node-name>`
   - `user-data`: set hostname, configure k3s role (`K3S_URL` + `K3S_TOKEN` env for agents, server flags for CP), register the k3s service
3. ISO attached as DVD drive in Hyper-V VM — cloud-init NoCloud datasource reads it on boot.
4. After first boot completes, DVD can be detached (or left attached; harmless after cloud-init runs).

PowerShell can create ISO files using `oscdimg.exe` (Windows ADK — added as Phase 0 prerequisite).

---

## Windows First-Boot Strategy (no sysprep)

Sysprep is avoided (limited to ~3 uses per install, breaks activation). Instead:

1. **Base Packer build** drops a sentinel file `C:\k8s-firstboot.pending` and registers a one-shot Scheduled Task (`k8s-firstboot`) that runs `C:\k8s-firstboot.ps1` on next boot then deletes itself and the sentinel.
2. `C:\k8s-firstboot.ps1` is a **template** baked into the base — it reads its parameters from `C:\k8s-node-config.json`, which is injected per-node.
3. `New-WindowsNodes.ps1` creates the differencing disk, mounts it via `Mount-VHD`, drops `k8s-node-config.json` (hostname, k3sServerIP, nodeToken, OS-appropriate settings), then `Dismount-VHD`. Completely offline — no network needed before k3s is configured.
4. On first boot the scheduled task runs, renames computer, configures k3s agent service, reboots once more to apply hostname.

`k8s-node-config.json` schema:
```json
{
  "hostname": "k8s-win-01",
  "k3sServerIP": "192.168.1.50",
  "nodeToken": "K10::...",
  "osVersion": "2025",
  "clusterDNS": "10.43.0.10",
  "clusterCIDR": "10.42.0.0/16",
  "serviceCIDR": "10.43.0.0/16"
}
```

---

## Sentinel Strategy

Current flat sentinels → hierarchical, per-resource sentinels:

```
output/sentinels/
  phase-0.done            (tools installed)
  phase-1.done            (vswitch)
  linux-base.done         (golden VHDX exists)
  win2022-base.done
  win2025-base.done
  node-k8s-cp-01.done     (VM created + booted)
  node-k8s-lnx-01.done
  node-k8s-win-01.done
  cp-bootstrap.done       (k3s server running, token retrieved)
  node-k8s-lnx-01-ready.done   (joined + Ready in kubectl)
  node-k8s-win-01-ready.done
  cni.done
  kubeconfig.done
```

This allows re-provisioning a single failed node (`-ForceNode k8s-win-01`) without touching the rest.

---

## Main.ps1 Updates

- Add `-ForceNode <name>` parameter to reset a single node's sentinels
- Add `-SkipWindowsNodes` shortcut (equivalent to `WindowsNodeSpecs = @()` override)
- Health check iterates `$script:WindowsNodeSpecs` to enumerate all expected nodes
- Parallel phase dispatch: phases 2+3 (base builds) launched as PowerShell background jobs, waited on together

---

## Verification Steps

1. `kubectl get nodes -o wide` — all N Linux + M Windows nodes Ready
2. `kubectl get nodes -l kubernetes.io/os=linux` — correct count
3. `kubectl get nodes -l kubernetes.io/os=windows` — correct count + correct OS version label
4. Deploy a test pod pinned to each node type and confirm scheduling
5. Zero-Windows run: set `$script:WindowsNodeSpecs = @()`, full rebuild — phases 5 and `win*-base.done` skipped entirely
6. Mixed-OS Windows: deploy pod with `nodeSelector: windows-version: 2025`, confirm it lands on a 2025 node
7. CNI swap test: set `$script:CNIPlugin = 'cilium'`, run Phase 8 — verify cilium pods Running

---

## Scope Boundaries

**Included in this change:**
- Configurable Linux worker count (0 = CP only)
- Configurable Windows nodes per OS version (0 = skip all Windows), mixing WS2022 and WS2025
- Differencing disk VM hierarchy for fast multi-node cloning
- CNI plugin variable (flannel default, cilium/multus extensible)
- Windows Server 2022 + 2025 base images (separate Packer builds, separate parent VHDXs)

**Excluded (future work):**
- HA control-plane (3 CPs with embedded etcd)
- Automatic IP reservation / static DHCP (nodes still get DHCP)
- Cilium/Multus actual configuration beyond applying manifests
- GPU pass-through or SR-IOV node specs

---

## Further Considerations

1. **`oscdimg` availability**: Creating Linux seed ISOs on Windows requires `oscdimg.exe` (Windows ADK). Phase 0 should add it as a prerequisite — check for `${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe` and install ADK via winget (`Microsoft.WindowsADK`) if absent.

2. **Golden VHDX must be read-only**: After the base Packer build, mark the parent VHDX read-only (`Set-ItemProperty -Name IsReadOnly`) before creating any differencing disks from it. Hyper-V requires the parent to not change after children are created. The build scripts should enforce this.

3. **Windows base build count**: Only build the WS2022 base if `WindowsNodeSpecs` contains an entry with `OSVersion = '2022'`, and similarly for 2025. If `WindowsNodeSpecs = @()`, skip Phase 3 entirely.

4. **Node-token timing**: The k3s node-token is only available after `Bootstrap-ControlPlane.ps1` completes (Phase 6). `New-WindowsNodes.ps1` (Phase 5) creates the VMs but does NOT boot them yet — or boots them and the first-boot script loops waiting for the token to appear in `k8s-node-config.json`. Cleaner: Phase 5 creates + starts VMs but they idle until Phase 6 writes the token, then Phase 7 triggers / waits for join. Consider injecting the token in a Phase 7 pre-step via `Mount-VHD` before signalling the VMs to proceed.

5. **Linux worker k3s agent install**: Linux workers use the same golden base VHDX as the control-plane. The cloud-init seed ISO for workers must set `K3S_URL` and `K3S_TOKEN` env vars and install the k3s agent service (not server). This logic lives entirely in the per-node `user-data` written by `New-LinuxNodes.ps1`, not in the base image.
