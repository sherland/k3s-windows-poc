# =============================================================================
# config/variables.ps1
# Central configuration for the Hyper-V Kubernetes cluster build.
# Edit this file before running Main.ps1.
# =============================================================================

# -----------------------------------------------------------------------------
# Credentials  <-- change before first run
# -----------------------------------------------------------------------------
$script:LinuxAdminUser  = 'k8sadmin'
$script:LinuxAdminPass  = 'ChangeMe123!'
$script:WinAdminUser    = 'Administrator'
$script:WinAdminPass    = 'ChangeMe123!'

# -----------------------------------------------------------------------------
# Control Plane
# -----------------------------------------------------------------------------
$script:ControlPlaneVMName  = 'k8s-cp-01'   # must be ≤15 chars (used as Windows-compatible k8s node name)
$script:ControlPlaneCPU     = 2
$script:ControlPlaneRAM     = 4096           # MB

# -----------------------------------------------------------------------------
# Linux Workers
# -----------------------------------------------------------------------------
$script:LinuxWorkerPrefix    = 'k8s-lnx'     # → k8s-lnx-01, k8s-lnx-02
$script:LinuxWorkerCount     = 2             # 0 = control-plane only
$script:LinuxWorkerCPU       = 2
$script:LinuxWorkerRAM       = 4096          # MB — primary worker (k8s-lnx-01)
$script:ExtraLinuxWorkerRAM  = 2048          # MB — additional workers (k8s-lnx-02 and beyond)

# -----------------------------------------------------------------------------
# Windows Workers
# Each entry: @{ Count = N; OSVersion = '2022'|'2025'; CPU = N; RAM = MB }
# Set to @() for zero Windows nodes.
# -----------------------------------------------------------------------------
$script:WindowsWorkerPrefix = 'k8s-win'     # → k8s-win-01, k8s-win-02 (≤10 chars so result stays ≤15)
$script:WindowsNodeSpecs    = @()  # No Windows nodes for Scenario B

# -----------------------------------------------------------------------------
# VM Disk
# -----------------------------------------------------------------------------
$script:DiskSizeGB = 60   # applied to all VMs

# -----------------------------------------------------------------------------
# CNI
# -----------------------------------------------------------------------------
$script:CNIPlugin      = 'multus'    # 'flannel' (embedded, default) | 'cilium' | 'multus'
$script:FlannelBackend = 'host-gw'   # 'host-gw' (L2, required for Windows on same vSwitch) | 'vxlan'

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
$script:vSwitchName  = 'k8s-external'
$script:HostNicName  = ''              # leave empty to auto-detect via default route
$script:ClusterCidr  = '10.42.0.0/16' # Pod CIDR (k3s default)
$script:ServiceCidr  = '10.43.0.0/16' # Service CIDR (k3s default)
$script:ClusterDnsIp = '10.43.0.10'   # CoreDNS ClusterIP (k3s default: 10th IP in service CIDR)

# -----------------------------------------------------------------------------
# Software Versions
# k3s is pinned — both Linux and Windows binaries must use the same version.
# containerd is pinned to v1.x — kubelet v1.32 requires CRI v1 gRPC API (removed in v2.x).
# -----------------------------------------------------------------------------
$script:K3sVersion        = 'v1.32.5+k3s1'
$script:ContainerdVersion = '1.7.32'
$script:FlannelVersion    = 'v0.25.7'   # Windows flanneld.exe + CNI plugin
$script:WinsCniVersion    = 'v0.3.0'    # windows-container-networking (win-bridge, win-overlay)
$script:MultusVersion     = 'v4.3.0'    # multus-cni meta-plugin (Linux only)
$script:CniPluginsVersion = 'v1.5.1'    # containernetworking/plugins — required for Multus secondary interfaces (macvlan, ipvlan, etc.)
$script:CiliumVersion     = '1.19.4'    # Cilium CNI (Linux only; latest stable)
$script:CalicoVersion     = 'v3.29.3'   # Calico CNI via tigera-operator Helm chart (Linux only; latest stable)
$script:PackerWingetId    = 'Hashicorp.Packer'
$script:KubectlWingetId   = 'Kubernetes.kubectl'

# -----------------------------------------------------------------------------
# Ubuntu ISO (auto-resolved from releases.ubuntu.com when left empty)
# -----------------------------------------------------------------------------
$script:UbuntuReleasesBaseUrl = 'https://releases.ubuntu.com/24.04'
$script:UbuntuISOUrl          = ''   # override to pin a specific ISO URL
$script:UbuntuISOChecksum     = ''   # override to pin a specific SHA256

# -----------------------------------------------------------------------------
# Windows Eval ISOs
# Set the LocalPath variable to use a pre-downloaded ISO; leave empty to download.
# -----------------------------------------------------------------------------
$script:WindowsEvalUrl2025      = 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'
$script:WindowsEvalUrl2022      = 'https://go.microsoft.com/fwlink/p/?LinkID=2195334&clcid=0x409&culture=en-us&country=US'
$script:WindowsISOLocalPath2025 = ''   # e.g. 'C:\ISOs\WS2025.iso'
$script:WindowsISOLocalPath2022 = ''   # e.g. 'C:\ISOs\WS2022.iso'

# -----------------------------------------------------------------------------
# Paths  (relative to repo root — do not change unless you restructure the repo)
# -----------------------------------------------------------------------------
$script:RepoRoot         = $PSScriptRoot | Split-Path -Parent
$script:OutputDir        = Join-Path $script:RepoRoot 'output'
$script:PackerLinuxDir   = Join-Path $script:RepoRoot 'packer\linux'
$script:PackerWindowsDir = Join-Path $script:RepoRoot 'packer\windows'
$script:VHDXStoreDir     = Join-Path $script:RepoRoot 'vhdx'   # root for all VHDXs

# SSH key used for Packer provisioning and for host→CP SSH during bootstrap
$script:SshKeyPath = Join-Path $script:OutputDir 'linux-build-key'

# -----------------------------------------------------------------------------
# Timeouts (seconds)
# -----------------------------------------------------------------------------
$script:VMBootTimeoutSec      = 300   # wait for VM to get an IP after start
$script:K3sReadyTimeoutSec    = 300   # wait for k3s to report active/Ready
$script:WinRMTimeoutSec       = 600   # wait for VMBus session after Windows boot
$script:NodeJoinTimeoutSec    = 300   # wait for node to appear in kubectl get nodes
$script:NodeReadyTimeoutSec   = 600   # wait for node to transition to Ready