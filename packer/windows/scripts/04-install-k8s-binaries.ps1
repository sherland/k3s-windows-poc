# =============================================================================
# packer/windows/scripts/04-install-k8s-binaries.ps1
# Install upstream Kubernetes binaries into the Windows base image:
#   - kubelet.exe, kube-proxy.exe, kubectl.exe
#   - flanneld CNI plugin (flannel.exe in CNI bin dir)
#   - win-bridge.exe, host-local.exe, hns.psm1
#
# Also writes STATIC files that are identical for all nodes derived from this base:
#   - C:\k\start-network.ps1      (creates cbr0 HNS network on first boot)
#   - C:\k\start-kube-proxy.ps1   (starts kube-proxy after cbr0 is ready)
#   - C:\k\kubelet-config.yaml    (KubeletConfiguration — cluster-level settings only)
#   - C:\k\cni\config\10-flannel.conflist
#
# Registers scheduled tasks: StartNetwork, StartKubeProxy (SYSTEM, at startup)
# Adds Kubernetes firewall rules.
# Updates containerd config.toml with CNI bin/conf dirs.
# Does NOT write per-node kubeconfigs or register the kubelet service.
# Those are done at first boot by C:\k8s-firstboot.ps1 (see 05-firstboot-setup.ps1).
#
# Environment variables injected by Packer:
#   K8S_VERSION       - e.g. v1.32.5
#   CLUSTER_DNS_IP    - CoreDNS cluster IP   (default: 10.43.0.10)
#   CLUSTER_CIDR      - Pod CIDR             (default: 10.42.0.0/16)
#   SERVICE_CIDR      - Service CIDR         (default: 10.43.0.0/16)
#   FLANNEL_VERSION   - flannel release tag  (default: v0.25.7)
#   WINS_CNI_VERSION  - windows-container-networking release (default: v0.3.0)
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Msg) Write-Host "[$(Get-Date -f HH:mm:ss)] $Msg" }

$K8sVersion    = $env:K8S_VERSION;   if (-not $K8sVersion)  { throw 'K8S_VERSION env var not set' }
$ClusterDnsIp  = if ($env:CLUSTER_DNS_IP)   { $env:CLUSTER_DNS_IP }   else { '10.43.0.10' }
$ClusterCidr   = if ($env:CLUSTER_CIDR)     { $env:CLUSTER_CIDR }     else { '10.42.0.0/16' }
$ServiceCidr   = if ($env:SERVICE_CIDR)     { $env:SERVICE_CIDR }     else { '10.43.0.0/16' }
$FlannelVersion = if ($env:FLANNEL_VERSION)  { $env:FLANNEL_VERSION }  else { 'v0.25.7' }
$WinCniVersion  = if ($env:WINS_CNI_VERSION) { $env:WINS_CNI_VERSION } else { 'v0.3.0' }

$KDir          = 'C:\k'
$CniBinDir     = 'C:\k\cni'
$CniConfDir    = 'C:\k\cni\config'
$KubeletDir    = 'C:\var\lib\kubelet'
$PkiDir        = 'C:\k\pki'
$KubeletPath   = "$KDir\kubelet.exe"
$KubectlPath   = "$KDir\kubectl.exe"
$KubeProxyPath = "$KDir\kube-proxy.exe"
$FlannelCniPath = "$CniBinDir\flannel.exe"
$HostLocalPath  = "$CniBinDir\host-local.exe"
$HnsPsmPath     = "$KDir\hns.psm1"

Write-Log "04-install-k8s-binaries: K8S_VERSION=$K8sVersion  FLANNEL=$FlannelVersion  WIN_CNI=$WinCniVersion"

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
foreach ($d in @($KDir, $CniBinDir, $CniConfDir, $KubeletDir, $PkiDir)) {
    $null = New-Item -ItemType Directory -Force -Path $d
}

# ---------------------------------------------------------------------------
# Download kubelet.exe
# ---------------------------------------------------------------------------
if (-not (Test-Path $KubeletPath)) {
    $url = "https://dl.k8s.io/release/$K8sVersion/bin/windows/amd64/kubelet.exe"
    Write-Log "04-install-k8s-binaries: Downloading kubelet.exe $K8sVersion"
    curl.exe -fsSL -o $KubeletPath $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: kubelet.exe from $url" }
} else { Write-Log "04-install-k8s-binaries: kubelet.exe already present" }

# ---------------------------------------------------------------------------
# Download kube-proxy.exe
# ---------------------------------------------------------------------------
if (-not (Test-Path $KubeProxyPath)) {
    $url = "https://dl.k8s.io/release/$K8sVersion/bin/windows/amd64/kube-proxy.exe"
    Write-Log "04-install-k8s-binaries: Downloading kube-proxy.exe $K8sVersion"
    curl.exe -fsSL -o $KubeProxyPath $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: kube-proxy.exe from $url" }
} else { Write-Log "04-install-k8s-binaries: kube-proxy.exe already present" }

# ---------------------------------------------------------------------------
# Download kubectl.exe
# ---------------------------------------------------------------------------
if (-not (Test-Path $KubectlPath)) {
    $url = "https://dl.k8s.io/release/$K8sVersion/bin/windows/amd64/kubectl.exe"
    Write-Log "04-install-k8s-binaries: Downloading kubectl.exe $K8sVersion"
    curl.exe -fsSL -o $KubectlPath $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: kubectl.exe from $url" }
} else { Write-Log "04-install-k8s-binaries: kubectl.exe already present" }

# ---------------------------------------------------------------------------
# Download CNI plugins
# ---------------------------------------------------------------------------

# win-bridge.exe + sdnbridge.exe + win-overlay.exe from microsoft/windows-container-networking
if (-not (Test-Path "$CniBinDir\sdnbridge.exe")) {
    $zip = "$env:TEMP\win-cni.zip"
    $url = "https://github.com/microsoft/windows-container-networking/releases/download/$WinCniVersion/windows-container-networking-cni-amd64-$WinCniVersion.zip"
    Write-Log "04-install-k8s-binaries: Downloading windows-container-networking $WinCniVersion"
    curl.exe -fsSL -L -o $zip $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: windows-container-networking from $url" }
    Expand-Archive -Path $zip -DestinationPath $CniBinDir -Force
    Remove-Item $zip -Force
    Write-Log "04-install-k8s-binaries: win-bridge.exe + sdnbridge.exe installed"
} else { Write-Log "04-install-k8s-binaries: sdnbridge.exe already present" }

# flannel CNI plugin — binary extracted from flannel Windows release
if (-not (Test-Path $FlannelCniPath)) {
    $tarPath = "$env:TEMP\flannel-windows.tar.gz"
    $url = "https://github.com/flannel-io/flannel/releases/download/$FlannelVersion/flannel-$FlannelVersion-windows-amd64.tar.gz"
    Write-Log "04-install-k8s-binaries: Downloading flannel Windows package $FlannelVersion"
    curl.exe -fsSL -L -o $tarPath $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: flannel Windows tar.gz from $url" }
    $extractDir = "$env:TEMP\flannel-cni-extract"
    $null = New-Item -ItemType Directory -Force -Path $extractDir
    tar.exe -xzf $tarPath -C $extractDir 2>&1 | Out-Null
    $extracted = Get-ChildItem $extractDir -Recurse -Filter '*.exe' | Select-Object -First 1
    if (-not $extracted) { throw "Could not find .exe in flannel Windows tar.gz" }
    Copy-Item $extracted.FullName $FlannelCniPath -Force
    Remove-Item $tarPath, $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "04-install-k8s-binaries: flannel CNI plugin installed"
} else { Write-Log "04-install-k8s-binaries: flannel CNI plugin already present" }

# hns.psm1 — required by start-network.ps1
if (-not (Test-Path $HnsPsmPath)) {
    $url = 'https://raw.githubusercontent.com/microsoft/SDN/master/Kubernetes/windows/hns.psm1'
    Write-Log "04-install-k8s-binaries: Downloading hns.psm1"
    curl.exe -fsSL -o $HnsPsmPath $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: hns.psm1 from $url" }
    Write-Log "04-install-k8s-binaries: hns.psm1 downloaded"
} else { Write-Log "04-install-k8s-binaries: hns.psm1 already present" }

# host-local IPAM from containernetworking/plugins
if (-not (Test-Path $HostLocalPath)) {
    $tgz = "$env:TEMP\cni-plugins.tgz"
    $url = 'https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-windows-amd64-v1.5.1.tgz'
    Write-Log "04-install-k8s-binaries: Downloading host-local IPAM plugin"
    curl.exe -fsSL -L -o $tgz $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: cni-plugins from $url" }
    tar.exe -xzf $tgz -C $CniBinDir 2>&1 | Out-Null
    Remove-Item $tgz -Force -ErrorAction SilentlyContinue
    Write-Log "04-install-k8s-binaries: host-local.exe installed"
} else { Write-Log "04-install-k8s-binaries: host-local.exe already present" }

# ---------------------------------------------------------------------------
# Write KubeletConfiguration (cluster-level; node-level settings added at first boot)
# ---------------------------------------------------------------------------
# Note: podInfraContainerImage moved from --pod-infra-container-image CLI flag
# (removed in k8s 1.31) to KubeletConfiguration in k8s 1.27+.
@"
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
clusterDNS:
  - "$ClusterDnsIp"
clusterDomain: "cluster.local"
resolvConf: ""
containerRuntimeEndpoint: "npipe:////./pipe/containerd-containerd"
registerNode: true
podInfraContainerImage: "mcr.microsoft.com/oss/kubernetes/pause:3.9"
"@ | Set-Content -Path "$KDir\kubelet-config.yaml" -Encoding ascii
Write-Log "04-install-k8s-binaries: kubelet-config.yaml written"

# ---------------------------------------------------------------------------
# Write start-kube-proxy.ps1
# kube-proxy needs --source-vip = cbr0 gateway (only known at runtime after StartNetwork runs)
# ---------------------------------------------------------------------------
@"
# C:\k\start-kube-proxy.ps1 - DO NOT EDIT (generated by 04-install-k8s-binaries.ps1)
`$ErrorActionPreference = 'Continue'
`$Log = 'C:\k\kube-proxy.log'
function KpLog(`$m) { "[`$(Get-Date -f HH:mm:ss)] `$m" | Tee-Object -FilePath `$Log -Append }

KpLog 'start-kube-proxy: waiting for cbr0 HNS network (created by StartNetwork task)...'
`$deadline = (Get-Date).AddSeconds(300)
`$hnsNet = `$null
while ((Get-Date) -lt `$deadline) {
    try { Import-Module 'C:\k\hns.psm1' -Force -ErrorAction SilentlyContinue
          `$hnsNet = Get-HnsNetwork | Where-Object { `$_.Name -eq 'cbr0' } } catch {}
    if (`$hnsNet) { break }
    Start-Sleep -Seconds 5
}
if (-not `$hnsNet) {
    KpLog 'start-kube-proxy: ERROR - cbr0 not found after 300s'
    exit 1
}
`$sourceVip = (`$hnsNet.Subnets | Select-Object -First 1).GatewayAddress
KpLog "start-kube-proxy: cbr0 found - source VIP = `$sourceVip"

`$args = @(
    '--v=4', '--proxy-mode=kernelspace',
    "--hostname-override=`$(`$env:COMPUTERNAME.ToLower())",
    '--kubeconfig=C:\k\kubeconfig.yaml',
    '--network-name=cbr0',
    "--source-vip=`$sourceVip",
    '--enable-dsr=false',
    "--cluster-cidr=$ClusterCidr"
)
KpLog "start-kube-proxy: exec kube-proxy.exe `$(`$args -join ' ')"
& 'C:\k\kube-proxy.exe' @args 2>&1 | Tee-Object -FilePath `$Log -Append
"@ | Set-Content -Path "$KDir\start-kube-proxy.ps1" -Encoding UTF8
Write-Log "04-install-k8s-binaries: start-kube-proxy.ps1 written"

# ---------------------------------------------------------------------------
# Write start-network.ps1
# ---------------------------------------------------------------------------
(@'
# C:\k\start-network.ps1 - Windows pod network setup (generated by 04-install-k8s-binaries.ps1)
$ErrorActionPreference = 'Continue'
$Log = 'C:\k\network.log'
function NLog($m) { "[$(Get-Date -f HH:mm:ss)] $m" | Tee-Object -FilePath $Log -Append }

$KDir        = 'C:\k'
$NodeName    = $env:COMPUTERNAME.ToLower()
$Kubeconfig  = "$KDir\kubeconfig.yaml"
$ClusterCidr = '__CLUSTER_CIDR__'
$ServiceCidr = '__SERVICE_CIDR__'
$DnsIp       = '__DNS_IP__'
$CniConfDir  = "$KDir\cni\config"

NLog "start-network: node=$NodeName"

# Wait for kubelet to register node and k3s to assign a pod CIDR (up to 10 min)
$deadline = (Get-Date).AddSeconds(600)
$podCidr   = $null
while ((Get-Date) -lt $deadline) {
    try {
        $raw = & "$KDir\kubectl.exe" --kubeconfig=$Kubeconfig get node $NodeName -o jsonpath='{.spec.podCIDR}' 2>$null
        if ($raw -match '\d+\.\d+\.\d+\.\d+/\d+') { $podCidr = $raw.Trim(); break }
    } catch {}
    NLog "start-network: waiting for pod CIDR on node $NodeName..."
    Start-Sleep 10
}
if (-not $podCidr) { NLog 'start-network: ERROR - no pod CIDR after 600s'; exit 1 }
NLog "start-network: pod CIDR = $podCidr"

$base      = ($podCidr -split '/')[0]
$octets    = $base -split '\.'
$octets[3] = '1'
$gateway   = $octets -join '.'
NLog "start-network: gateway = $gateway"

$null = New-Item -ItemType Directory -Force -Path $CniConfDir
@"
{
  "name": "cbr0",
  "cniVersion": "0.3.0",
  "plugins": [
    {
      "type": "sdnbridge",
      "ipam": {
        "type": "host-local",
        "subnet": "$podCidr",
        "routes": [{ "dst": "0.0.0.0/0", "gw": "$gateway" }]
      },
      "dns": {
        "Nameservers": ["$DnsIp"],
        "Search": ["svc.cluster.local", "cluster.local"]
      },
      "policies": [
        {"Name":"EndpointPolicy","Value":{"Type":"OutBoundNAT","ExceptionList":["$ClusterCidr","$ServiceCidr"]}},
        {"Name":"EndpointPolicy","Value":{"Type":"ROUTE","DestinationPrefix":"$ServiceCidr","NeedEncap":true}},
        {"Name":"EndpointPolicy","Value":{"Type":"ROUTE","DestinationPrefix":"$ClusterCidr","NeedEncap":true}}
      ]
    }
  ]
}
"@ | Set-Content -Path "$CniConfDir\10-flannel.conflist" -Encoding ascii
NLog "start-network: CNI conflist written with podCIDR $podCidr"

Import-Module 'C:\k\hns.psm1' -Force -ErrorAction SilentlyContinue

$hns = Get-HnsNetwork -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'cbr0' }
if (-not $hns) {
    New-HnsNetwork -Type L2Bridge -Name cbr0 -AddressPrefix $podCidr -Gateway $gateway | Out-Null
    NLog "start-network: cbr0 HNS L2Bridge created (subnet=$podCidr gateway=$gateway)"
} else { NLog 'start-network: cbr0 already exists' }

try {
    $nodes = (& "$KDir\kubectl.exe" --kubeconfig=$Kubeconfig get nodes -o json 2>$null | ConvertFrom-Json).items
    foreach ($n in $nodes) {
        if ($n.metadata.labels.'kubernetes.io/os' -eq 'windows') { continue }
        $lCidr = $n.spec.podCIDR
        $lIp = ($n.status.addresses | Where-Object { $_.type -eq 'InternalIP' }).address | Select-Object -First 1
        if ($lCidr -and $lIp) {
            $lBase = ($lCidr -split '/')[0]
            route add $lBase mask 255.255.255.0 $lIp metric 5 2>$null | Out-Null
            NLog "start-network: route added $lCidr via $lIp"
        }
    }
} catch { NLog "start-network: WARNING route setup: $_" }

NLog "start-network: complete. cbr0=$podCidr gateway=$gateway"
'@ -replace '__CLUSTER_CIDR__', $ClusterCidr `
   -replace '__SERVICE_CIDR__',  $ServiceCidr `
   -replace '__DNS_IP__',        $ClusterDnsIp) |
    Set-Content -Path "$KDir\start-network.ps1" -Encoding UTF8
Write-Log "04-install-k8s-binaries: start-network.ps1 written"

# ---------------------------------------------------------------------------
# Register StartNetwork and StartKubeProxy as scheduled tasks
# ---------------------------------------------------------------------------
foreach ($taskDef in @(
    @{ Name = 'StartNetwork';   Script = 'start-network.ps1';    Restart = 3 },
    @{ Name = 'StartKubeProxy'; Script = 'start-kube-proxy.ps1'; Restart = 5 }
)) {
    Unregister-ScheduledTask -TaskName $taskDef.Name -Confirm:$false -ErrorAction SilentlyContinue
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NonInteractive -ExecutionPolicy Bypass -File C:\k\$($taskDef.Script)"
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $settings  = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew -RestartCount $taskDef.Restart `
        -RestartInterval (New-TimeSpan -Minutes 2) `
        -ExecutionTimeLimit (New-TimeSpan -Hours 0)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskDef.Name `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Log "04-install-k8s-binaries: $($taskDef.Name) scheduled task registered"
}

# ---------------------------------------------------------------------------
# Firewall rules for Kubernetes
# ---------------------------------------------------------------------------
Write-Log "04-install-k8s-binaries: Configuring firewall rules..."
$fwRules = @(
    @{ N = 'k8s-kubelet';      P = 'TCP'; Port = 10250;         D = 'kubelet API' },
    @{ N = 'k8s-nodeport-tcp'; P = 'TCP'; Port = '30000-32767'; D = 'NodePort TCP' },
    @{ N = 'k8s-nodeport-udp'; P = 'UDP'; Port = '30000-32767'; D = 'NodePort UDP' },
    @{ N = 'WinRM-HTTP';       P = 'TCP'; Port = 5985;          D = 'WinRM HTTP' }
)
foreach ($r in $fwRules) {
    if (-not (Get-NetFirewallRule -DisplayName $r.N -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $r.N -Direction Inbound -Action Allow `
            -Protocol $r.P -LocalPort $r.Port -Description $r.D | Out-Null
        Write-Log "04-install-k8s-binaries: Firewall rule added: $($r.N)"
    }
}

# ---------------------------------------------------------------------------
# Update containerd config.toml with CNI bin/conf directories
# ---------------------------------------------------------------------------
$containerdConf = 'C:\containerd\config\config.toml'
if (Test-Path $containerdConf) {
    $cfg = Get-Content $containerdConf -Raw
    $cniSection = '[plugins."io.containerd.grpc.v1.cri".cni]'
    if ($cfg -notmatch [regex]::Escape($cniSection)) {
        $CniBinEsc  = $CniBinDir  -replace '\\', '\\\\'
        $CniConfEsc = $CniConfDir -replace '\\', '\\\\'
        $cfg += "`n$cniSection`n  bin_dir  = `"$CniBinEsc`"`n  conf_dir = `"$CniConfEsc`"`n"
        Set-Content -Path $containerdConf -Value $cfg -Encoding ascii
        Write-Log "04-install-k8s-binaries: Added [cni] section to containerd config.toml"
        Restart-Service containerd -Force
        Start-Sleep -Seconds 5
        Write-Log "04-install-k8s-binaries: containerd restarted"
    } else {
        Write-Log "04-install-k8s-binaries: containerd config.toml already has [cni] section"
    }
} else {
    Write-Log "04-install-k8s-binaries: WARNING - $containerdConf not found"
}

# ---------------------------------------------------------------------------
# Add C:\k to system PATH
# ---------------------------------------------------------------------------
$mp = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
if ($mp -notlike "*$KDir*") {
    [Environment]::SetEnvironmentVariable('PATH', "$mp;$KDir", 'Machine')
    $env:PATH = "$env:PATH;$KDir"
    Write-Log "04-install-k8s-binaries: C:\k added to system PATH"
}

Write-Log "04-install-k8s-binaries: Done."
Write-Log "04-install-k8s-binaries: On first boot, k8s-firstboot.ps1 will:"
Write-Log "  1. Read C:\k8s-node-config.json (injected offline by Join-Nodes.ps1)"
Write-Log "  2. Write kubeconfigs to C:\k\"
Write-Log "  3. Register and start kubelet service"
Write-Log "  4. Rename computer, then reboot"
Write-Log "  5. StartNetwork + StartKubeProxy tasks run after the reboot"
