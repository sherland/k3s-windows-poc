# Plan: Hyper-V Kubernetes Cluster (Linux master + Windows worker)

## Architecture

```
Windows 11 Host (Hyper-V)
├── Linux VM  (Ubuntu 24.04 LTS)        → k3s SERVER  (control plane + Linux node)
│     └── External vSwitch              → LAN IP from router
└── Windows Server VM (WS 2025 Core)   → k3s AGENT   (Windows worker node)
      └── External vSwitch              → LAN IP from router

Host artefacts produced:
  output/kubeconfig.yaml               ← merged kubeconfig for kubectl
  output/cluster-info.txt              ← IPs, node names, credentials ref
  config/variables.ps1                 ← editable credentials + sizing
```

## Technology Choices

| Concern               | Choice                                      |
|-----------------------|---------------------------------------------|
| Virtualisation        | Hyper-V (Windows 11 host)                   |
| Image build           | Packer with `hyperv-iso` builder            |
| Linux distro          | Ubuntu 24.04 LTS (Noble)                    |
| Windows edition       | Windows Server 2025 Core evaluation (trial) |
| K8s distribution      | k3s (server on Linux, agent on Windows)     |
| Windows runtime       | containerd + HCS (Hyper-V isolation)        |
| Windows ISO source    | Auto-download from Microsoft Eval Center    |
| Network               | External vSwitch (VMs get router DHCP IPs)  |
| Credentials           | Defined in `config/variables.ps1`           |
| Container isolation   | Hyper-V isolation (nested virt on WS VM)    |

## Repository Layout

```
docker-windows-poc/
├── config/
│   └── variables.ps1            # VM sizing, credentials, switch name, k3s version
├── packer/
│   ├── linux/
│   │   ├── ubuntu.pkr.hcl       # Packer template for Ubuntu VM
│   │   ├── http/
│   │   │   └── user-data        # cloud-init autoinstall
│   │   └── scripts/
│   │       ├── 01-base.sh       # apt update, tools
│   │       ├── 02-k3s-server.sh # Install k3s server, write token/IP to shared location
│   │       └── 03-export-kubeconfig.sh
│   └── windows/
│       ├── winserver.pkr.hcl    # Packer template for Windows Server VM
│       ├── autounattend/
│       │   └── autounattend.xml # Unattended install answer file
│       └── scripts/
│           ├── 01-base.ps1      # WinRM, updates, Set-ExecutionPolicy
│           ├── 02-containers.ps1# Install-WindowsFeature Containers, Hyper-V
│           ├── 03-containerd.ps1# Download + configure containerd for Windows
│           ├── 04-k3s-agent.ps1 # Download k3s.exe, register as service, join cluster
│           └── 05-reboot-loop.ps1 # Handles multi-reboot sequence via scheduled task
├── scripts/
│   ├── Install-Prerequisites.ps1  # Chocolatey, Packer, kubectl on host
│   ├── New-HyperVSwitch.ps1       # Idempotent external vSwitch creation
│   ├── Build-LinuxVM.ps1          # Invoke packer build for Ubuntu
│   ├── Build-WindowsVM.ps1        # Download ISO, invoke packer build for WS
│   ├── Join-WindowsNode.ps1       # Post-build: start WS VM, trigger k3s agent join
│   ├── Export-KubeConfig.ps1      # Pull kubeconfig from Linux VM → output/
│   └── Main.ps1                   # Orchestrator: calls all steps in order
└── output/                        # Git-ignored; generated at runtime
    ├── kubeconfig.yaml
    └── cluster-info.txt
```

## Step-by-step Execution Flow

### Phase 0 — Host prerequisites (`Install-Prerequisites.ps1`)
- Ensure Hyper-V Windows feature is enabled; if not, enable it and **automatically reboot** (script re-registers itself as a Run-Once task to continue after reboot)
- Install missing host tools via **winget** (preferred; exact IDs below), falling back to direct download only if winget itself is absent:
  - `packer`  → `Hashicorp.Packer`
  - `kubectl` → `Kubernetes.kubectl`
  - `openssh` client (for SSH to Linux VM) → built-in Windows feature `OpenSSH.Client~~~~0.0.1.0` via `Add-WindowsCapability`
- All winget installs use `--exact --id <id> --accept-package-agreements --accept-source-agreements`
- After installs, **verify each binary** is on PATH and responds to `--version`; abort with a clear message if any tool is missing after install
- Sentinel: skip if all tools already present and Hyper-V feature already enabled

### Phase 1 — Network (`New-HyperVSwitch.ps1`)
- Create external Hyper-V vSwitch bound to the host's primary NIC (idempotent)
- Switch name stored in `config/variables.ps1`

### Phase 2 — Build Linux VM (`Build-LinuxVM.ps1`)
- Packer `hyperv-iso` builder boots Ubuntu ISO
- `user-data` (cloud-init autoinstall) handles partitioning + user creation unattended; IP is DHCP (no static needed — token is read by the host post-build via SSH, and kubeconfig IP is discovered at export time)
- Provisioner scripts:
  1. `01-base.sh` — apt upgrade, curl, open-iscsi, nfs-common
  2. `02-k3s-server.sh` — `curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=… sh -`; waits for node Ready
  3. `03-export-kubeconfig.sh` — copies `/etc/rancher/k3s/k3s.yaml` to a Packer-accessible path with real server IP substituted
- Packer shuts down and exports the VM (VHDX); host starts the VM
- Host script SSHes in, reads `/var/lib/rancher/k3s/server/node-token` and the VM's current IP — both stored in memory for Phase 4

### Phase 3 — Download Windows Server ISO (`Build-WindowsVM.ps1`)
- HTTP POST to Microsoft Eval Center form → parses redirect → downloads ISO to `packer/windows/iso/`
- SHA256 verified against known hash (or skipped with warning if hash changes)

### Phase 4 — Build Windows Server VM (`Build-WindowsVM.ps1` cont.)
- Packer `hyperv-iso` builder boots WS 2025 Core ISO with `autounattend.xml`
- `autounattend.xml` handles: edition selection, disk layout, admin password, WinRM enable
- Provisioner scripts via WinRM:
  1. `01-base.ps1` — Set-ExecutionPolicy, disable firewall for provisioning, Windows Update (optional)
  2. `02-containers.ps1` — `Install-WindowsFeature Containers, Hyper-V`; sets Run-Once registry key; calls `Restart-Computer -Force`; Packer `windows-restart` provisioner waits for WinRM automatically
  3. `03-containerd.ps1` — download containerd release zip, extract to `C:\containerd`, register service, configure `config.toml` for Hyper-V isolation, pull `mcr.microsoft.com/windows/nanoserver` base image
  4. `04-k3s-agent.ps1` — download `k3s.exe` for Windows; `K3S_URL` and `K3S_TOKEN` injected automatically as Packer variables (host reads token from Linux VM via SSH after Phase 2 completes); register `k3s-agent` as a Windows Service via `sc.exe`; start service
- Enable nested virtualisation: `Set-VMProcessor -VMName … -ExposeVirtualizationExtensions $true` — set by host script before the provisioning boot, fully scripted

### Phase 5 — Join & verify (`Join-WindowsNode.ps1`)
- Waits for Windows node to appear in `kubectl get nodes`
- Labels node: `kubernetes.io/os=windows`
- Verifies Linux node Ready with label `kubernetes.io/os=linux`

### Phase 6 — Export kubeconfig (`Export-KubeConfig.ps1`)
- SCP or Hyper-V guest file copy of `/etc/rancher/k3s/k3s.yaml` from Linux VM
- Replaces `127.0.0.1` with actual Linux VM IP
- Writes to `output/kubeconfig.yaml`
- Writes `output/cluster-info.txt` with IPs, node names, credentials reference

### Phase 7 — `Main.ps1` orchestrates phases 0-6
- Each phase function is **idempotent**: checks a sentinel condition before doing work (e.g. VM already exists → skip build, k3s already running → skip install)
- `-StartFromPhase <int>` parameter to resume from a specific phase after a failure
- `-ForcePhase <int[]>` parameter to re-run specific phases regardless of sentinel
- Coloured console output with timestamps and phase banners
- **Each phase ends with a `Assert-*` verification function** that confirms the phase outcome before proceeding; on failure the script stops with a clear error message and remediation hint
- The script is safe to run multiple times end-to-end; already-completed phases are skipped in seconds

## Idempotency & Verification Contract

Every phase follows this pattern:

```
Test-PhaseNComplete   # fast sentinel check → skip if true
  ↓ (not complete)
Invoke-PhaseN         # do the work
  ↓
Assert-PhaseNComplete # verify outcome; throw on failure with remediation hint
  ↓
Write-PhaseSuccess    # log timestamp + green banner
```

Sentinel checks (examples):
- Phase 0: all binaries on PATH + Hyper-V feature state
- Phase 1: vSwitch exists with correct adapter binding
- Phase 2: VM `$LinuxVMName` exists, is running, SSH responds, k3s server is Active
- Phase 3: ISO file exists at expected path with matching SHA256
- Phase 4: VM `$WindowsVMName` exists, is running, WinRM responds, k3s agent service Running
- Phase 5: `kubectl get node <winNodeName>` returns Ready
- Phase 6: `output/kubeconfig.yaml` exists and `kubectl --kubeconfig … cluster-info` succeeds

The `Assert-*` functions are also usable standalone as a **health-check** after the full run:
```powershell
. .\scripts\Main.ps1 -HealthCheckOnly
```

## Host Software Installation (`Install-Prerequisites.ps1`)

Winget package IDs (pinned to latest stable, no version lock):

| Tool     | Winget ID                  | Fallback |
|----------|----------------------------|----------|
| Packer   | `Hashicorp.Packer`         | GitHub releases API |
| kubectl  | `Kubernetes.kubectl`       | dl.k8s.io |
| OpenSSH client | Windows optional feature | built-in since Win10 1809 |

All installs are idempotent: `winget list --id <id>` checked first; install only if absent or upgrade available.

## Key Configuration (`config/variables.ps1`)

```powershell
# VM sizing
$LinuxVMName      = 'k8s-linux-master'
$WindowsVMName    = 'k8s-windows-worker'
$LinuxMemoryGB    = 4
$WindowsMemoryGB  = 8
$LinuxCPU         = 2
$WindowsCPU       = 4
$DiskSizeGB       = 60

# Credentials  (change before first run)
$LinuxAdminUser   = 'k8sadmin'
$LinuxAdminPass   = 'ChangeMe123!'
$WinAdminPass     = 'ChangeMe123!'

# Network
$vSwitchName      = 'k8s-external'

# Versions (update to latest at time of run)
$K3sVersion       = 'v1.30.2+k3s1'
$ContainerdVersion = '1.7.18'
$UbuntuISOUrl     = 'https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso'
$UbuntuISOChecksum = 'sha256:...'
```

## Reboot Automation Strategy (Windows VM)

Fully automatic — no user interaction required.

Because `Install-WindowsFeature -Restart` inside Packer kills WinRM mid-session:

1. `02-containers.ps1` creates a Run-Once registry key pointing to `05-reboot-loop.ps1`
2. Initiates `Restart-Computer -Force`
3. Packer uses the built-in `windows-restart` provisioner, which polls WinRM until the VM responds (up to configurable timeout)
4. After WinRM is back, `05-reboot-loop.ps1` verifies the features are installed, removes the Run-Once key, and signals completion via a sentinel registry value
5. Packer continues automatically with `03-containerd.ps1` — no manual steps

## Nested Virtualisation Note

Hyper-V isolation inside the Windows Server VM requires nested virt. This must be set **before** the VM is powered on for the Hyper-V feature installation step:

```powershell
Set-VMProcessor -VMName $WindowsVMName -ExposeVirtualizationExtensions $true
```

Packer cannot do this itself (it's a host-side Hyper-V setting). `Build-WindowsVM.ps1` will:
1. Let Packer create the VM from ISO up to first shutdown (Packer `shutdown_command`)
2. Before starting the post-build provisioning pass, run `Set-VMProcessor`
3. Start the VM again for provisioning phases 2-4

Alternatively, the VHDX is built first (with a minimal autounattend), then a separate `New-VM` + `Set-VMProcessor` + start sequence handles feature installation and k3s agent setup outside of Packer.

## Output Files

`output/kubeconfig.yaml` — standard kubeconfig; usage:
```
$env:KUBECONFIG = "$PWD\output\kubeconfig.yaml"
kubectl get nodes -o wide
```

`output/cluster-info.txt`:
```
Linux master IP : 192.168.x.y
Windows worker IP: 192.168.x.z
kubectl context : k8s-hyper-v
Linux SSH       : ssh k8sadmin@192.168.x.y
Windows RDP/SSH : (disabled in Core; use Enter-PSSession)
Credentials     : see config/variables.ps1
```

## Decisions (resolved)

1. **Ubuntu ISO checksum** — fetched dynamically at runtime from the Ubuntu releases page (SHA256SUMS file).
2. **Windows Eval Center download** — automated HTTP download; script falls back to prompting for a local path only if the download fails.
3. **Packer communication** — SSH for Linux, WinRM for Windows.
4. **k3s token passing** — fully automatic: host SSHes into Linux VM after Phase 2, reads the node-token, passes it as a Packer variable to the Windows build. No manual steps.
5. **IPs** — DHCP throughout. The kubeconfig and cluster-info.txt are written with the IP discovered at export time. If the VM's DHCP lease changes after a reboot, re-run `Export-KubeConfig.ps1` to refresh. Static IPs are only configured if DHCP proves unreliable in practice.
