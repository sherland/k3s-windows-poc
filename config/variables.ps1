# =============================================================================
# config/variables.ps1
# Central configuration for the Hyper-V Kubernetes cluster build.
# Edit this file before running Main.ps1.
# =============================================================================

# -----------------------------------------------------------------------------
# VM Names
# -----------------------------------------------------------------------------
$script:LinuxVMName    = 'k8s-linux-master'
$script:WindowsVMName  = 'k8s-windows-worker'  # Hyper-V VM name
$script:WindowsNodeName = 'k8s-win-worker'      # Kubernetes node name (Windows hostname, max 15 chars)

# -----------------------------------------------------------------------------
# VM Sizing
# -----------------------------------------------------------------------------
$script:LinuxMemoryGB   = 4
$script:WindowsMemoryGB = 7
$script:LinuxCPU        = 2
$script:WindowsCPU      = 4
$script:DiskSizeGB      = 60   # applied to both VMs

# -----------------------------------------------------------------------------
# Credentials  <-- change before first run
# -----------------------------------------------------------------------------
$script:LinuxAdminUser  = 'k8sadmin'
$script:LinuxAdminPass  = 'ChangeMe123!'
$script:WinAdminUser    = 'Administrator'
$script:WinAdminPass    = 'ChangeMe123!'

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
# Name of the Hyper-V external vSwitch that will be created / reused
$script:vSwitchName     = 'k8s-external'

# Leave empty to auto-detect the host's primary connected NIC
$script:HostNicName     = ''

# -----------------------------------------------------------------------------
# Software Versions
# Packer, kubectl, and containerd versions are resolved at runtime from
# their respective release APIs when set to 'latest'.
# k3s version is pinned here so both VMs use the same binary; update as needed.
# -----------------------------------------------------------------------------
$script:K3sVersion          = 'v1.32.5+k3s1'
$script:ContainerdVersion   = '1.7.32'  # kubelet v1.32 requires containerd v1.x (CRI v1 gRPC API); containerd v2.x removed it
$script:PackerWingetId      = 'Hashicorp.Packer'
$script:KubectlWingetId     = 'Kubernetes.kubectl'

# Flannel version used for Windows flanneld.exe and CNI plugin.
# Must be compatible with the k3s-embedded flannel (host-gw backend, same Network CIDR).
$script:FlannelVersion      = 'v0.25.7'

# windows-container-networking release for win-bridge.exe / win-overlay.exe
$script:WinsCniVersion      = 'v0.3.0'

# -----------------------------------------------------------------------------
# Cluster Networking
# These must match k3s server defaults (or override them if you pass
# --cluster-cidr / --service-cidr to k3s).
# CoreDNS is always the 10th IP in the service CIDR (k3s default: 10.43.0.10).
# -----------------------------------------------------------------------------
$script:ClusterCidr   = '10.42.0.0/16'   # Pod CIDR (k3s default)
$script:ServiceCidr   = '10.43.0.0/16'   # Service CIDR (k3s default)
$script:ClusterDnsIp  = '10.43.0.10'     # CoreDNS ClusterIP (k3s default)

# -----------------------------------------------------------------------------
# Ubuntu ISO
# URL and SHA256 are resolved dynamically from the Ubuntu releases page.
# Override here to pin a specific release.
# -----------------------------------------------------------------------------
$script:UbuntuReleasesBaseUrl = 'https://releases.ubuntu.com/24.04'
$script:UbuntuISOUrl          = ''   # auto-resolved when empty
$script:UbuntuISOChecksum     = ''   # auto-resolved when empty

# -----------------------------------------------------------------------------
# Windows Server 2025 Evaluation ISO
# The download URL is obtained automatically from the Microsoft Eval Center.
# Set $script:WindowsISOLocalPath to skip the download (use a pre-existing ISO).
# -----------------------------------------------------------------------------
$script:WindowsISOLocalPath = ''   # e.g. 'C:\ISOs\WS2025.iso' — leave empty to auto-download
$script:WindowsEvalUrl      = 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'

# -----------------------------------------------------------------------------
# Paths  (relative to repo root — do not change unless you restructure the repo)
# -----------------------------------------------------------------------------
$script:RepoRoot         = $PSScriptRoot | Split-Path -Parent
$script:OutputDir        = Join-Path $script:RepoRoot 'output'
$script:PackerLinuxDir   = Join-Path $script:RepoRoot 'packer\linux'
$script:PackerWindowsDir = Join-Path $script:RepoRoot 'packer\windows'
$script:VHDXStoreDir     = Join-Path $script:RepoRoot 'vhdx'   # where Packer writes VHDXs

# SSH key generated during Linux VM build (host reads token / kubeconfig via this key)
$script:SshKeyPath = Join-Path $script:OutputDir 'linux-build-key'

# -----------------------------------------------------------------------------
# Timeouts (seconds)
# -----------------------------------------------------------------------------
$script:VMBootTimeoutSec      = 300   # wait for VM to become reachable after start
$script:K3sReadyTimeoutSec    = 300   # wait for k3s server to report Ready
$script:WinRMTimeoutSec       = 600   # wait for WinRM to respond after reboot
$script:NodeJoinTimeoutSec    = 300   # wait for Windows node to register with k3s (appear in kubectl)
$script:NodeReadyTimeoutSec   = 600   # wait for Windows node to transition to Ready after registration
