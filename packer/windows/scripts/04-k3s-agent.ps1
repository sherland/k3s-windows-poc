# =============================================================================
# packer/windows/scripts/04-k3s-agent.ps1
# Install upstream Kubernetes components for a Windows worker node:
#   - kubelet.exe   (registers this node with the k3s control plane)
#   - flanneld.exe  (programs host-gw routes and creates the cbr0 HNS network)
#   - kube-proxy    (scheduled task; waits for cbr0 then starts kube-proxy.exe)
#   - CNI plugins   (flannel CNI wrapper + win-bridge + host-local)
#
# k3s is fully Kubernetes-API-compliant — upstream kubelet and flanneld work
# unchanged.  We pass the k3s admin kubeconfig (KUBECONFIG_B64) for kubelet,
# and a dedicated flannel ServiceAccount kubeconfig (FLANNEL_KUBECONFIG_B64)
# for flanneld so it only has node-read permissions.
#
# Environment variables injected by Packer:
#   K8S_VERSION            - e.g. v1.32.5  (k3s version with +k3sN suffix stripped)
#   K3S_SERVER_IP          - IP of the Linux VM running k3s
#   KUBECONFIG_B64         - base64(k3s admin kubeconfig, server IP already patched)
#   FLANNEL_KUBECONFIG_B64 - base64(flannel ServiceAccount kubeconfig)
#   CLUSTER_DNS_IP         - CoreDNS cluster IP  (default: 10.43.0.10)
#   CLUSTER_CIDR           - Pod CIDR            (default: 10.42.0.0/16)
#   SERVICE_CIDR           - Service CIDR        (default: 10.43.0.0/16)
#   FLANNEL_VERSION        - flannel release tag  (default: v0.25.7)
#   WINS_CNI_VERSION       - windows-container-networking release (default: v0.3.0)
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Msg) Write-Host "[$(Get-Date -f HH:mm:ss)] $Msg" }

$K8sVersion           = $env:K8S_VERSION;            if (-not $K8sVersion)           { throw 'K8S_VERSION env var not set' }
$ServerIp             = $env:K3S_SERVER_IP;           if (-not $ServerIp)             { throw 'K3S_SERVER_IP env var not set' }
$KubeconfigB64        = $env:KUBECONFIG_B64;          if (-not $KubeconfigB64)        { throw 'KUBECONFIG_B64 env var not set' }
$FlannelKubeconfigB64 = $env:FLANNEL_KUBECONFIG_B64;  if (-not $FlannelKubeconfigB64) { throw 'FLANNEL_KUBECONFIG_B64 env var not set' }
$ClusterDnsIp   = if ($env:CLUSTER_DNS_IP)   { $env:CLUSTER_DNS_IP }   else { '10.43.0.10' }
$ClusterCidr    = if ($env:CLUSTER_CIDR)     { $env:CLUSTER_CIDR }     else { '10.42.0.0/16' }
$ServiceCidr    = if ($env:SERVICE_CIDR)     { $env:SERVICE_CIDR }     else { '10.43.0.0/16' }
$FlannelVersion = if ($env:FLANNEL_VERSION)  { $env:FLANNEL_VERSION }  else { 'v0.25.7' }
$WinCniVersion  = if ($env:WINS_CNI_VERSION) { $env:WINS_CNI_VERSION } else { 'v0.3.0' }

$KDir             = 'C:\k'
$CniBinDir        = 'C:\k\cni'
$CniConfDir       = 'C:\k\cni\config'
$KubeletDir       = 'C:\var\lib\kubelet'
$PkiDir           = 'C:\k\pki'
$KubeletPath      = "$KDir\kubelet.exe"
$KubectlPath      = "$KDir\kubectl.exe"
$KubeProxyPath    = "$KDir\kube-proxy.exe"
$FlannetCniPath   = "$CniBinDir\flannel.exe"
$HostLocalPath    = "$CniBinDir\host-local.exe"
$kubeconfigPath   = "$KDir\kubeconfig.yaml"
$flannelKubeconfigPath = "$KDir\flannel-kubeconfig.yaml"

Write-Log "04-k3s-agent: Installing upstream kubelet $K8sVersion + flanneld $FlannelVersion"

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
foreach ($d in @($KDir, $CniBinDir, $CniConfDir, $KubeletDir, $PkiDir)) {
    $null = New-Item -ItemType Directory -Force -Path $d
}

# ---------------------------------------------------------------------------
# Write kubeconfigs (decoded from base64 Packer variables)
# ---------------------------------------------------------------------------
[System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String($KubeconfigB64)) |
    Set-Content -Path $kubeconfigPath -Encoding UTF8
Write-Log "04-k3s-agent: Admin kubeconfig written to $kubeconfigPath"

[System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String($FlannelKubeconfigB64)) |
    Set-Content -Path $flannelKubeconfigPath -Encoding UTF8
Write-Log "04-k3s-agent: Flannel kubeconfig written to $flannelKubeconfigPath"

# Lock down both kubeconfig files to SYSTEM + Administrators only
foreach ($f in @($kubeconfigPath, $flannelKubeconfigPath)) {
    $acl = Get-Acl $f
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM',        'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('Administrators', 'FullControl', 'Allow')))
    Set-Acl -Path $f -AclObject $acl
}

# ---------------------------------------------------------------------------
# Download kubelet.exe from the official Kubernetes release mirror
# ---------------------------------------------------------------------------
if (-not (Test-Path $KubeletPath)) {
    $url = "https://dl.k8s.io/release/$K8sVersion/bin/windows/amd64/kubelet.exe"
    Write-Log "04-k3s-agent: Downloading kubelet.exe $K8sVersion"
    curl.exe -fsSL -o $KubeletPath $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: kubelet.exe from $url" }
} else { Write-Log "04-k3s-agent: kubelet.exe already present" }

# ---------------------------------------------------------------------------
# Download kube-proxy.exe
# ---------------------------------------------------------------------------
if (-not (Test-Path $KubeProxyPath)) {
    $url = "https://dl.k8s.io/release/$K8sVersion/bin/windows/amd64/kube-proxy.exe"
    Write-Log "04-k3s-agent: Downloading kube-proxy.exe $K8sVersion"
    curl.exe -fsSL -o $KubeProxyPath $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: kube-proxy.exe from $url" }
} else { Write-Log "04-k3s-agent: kube-proxy.exe already present" }

# ---------------------------------------------------------------------------
# Download kubectl.exe (used by start-network.ps1 to query pod CIDR from k3s)
# ---------------------------------------------------------------------------
if (-not (Test-Path $KubectlPath)) {
    $url = "https://dl.k8s.io/release/$K8sVersion/bin/windows/amd64/kubectl.exe"
    Write-Log "04-k3s-agent: Downloading kubectl.exe $K8sVersion"
    curl.exe -fsSL -o $KubectlPath $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: kubectl.exe from $url" }
} else { Write-Log "04-k3s-agent: kubectl.exe already present" }

# ---------------------------------------------------------------------------
# Download CNI plugins
# ---------------------------------------------------------------------------
Write-Log "04-k3s-agent: Downloading CNI plugins..."

# win-bridge.exe + win-overlay.exe from microsoft/windows-container-networking
if (-not (Test-Path "$CniBinDir\win-bridge.exe")) {
    $zip = "$env:TEMP\win-cni.zip"
    $url = "https://github.com/microsoft/windows-container-networking/releases/download/$WinCniVersion/windows-container-networking-cni-amd64-$WinCniVersion.zip"
    curl.exe -fsSL -L -o $zip $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: windows-container-networking" }
    Expand-Archive -Path $zip -DestinationPath $CniBinDir -Force
    Remove-Item $zip -Force
    Write-Log "04-k3s-agent: win-bridge.exe installed"
} else { Write-Log "04-k3s-agent: win-bridge.exe already present" }

# flannel CNI plugin (wrapper that delegates to win-bridge)
# Packed inside flannel-vX.Y.Z-windows-amd64.tar.gz as flanneld.exe (same binary, acts as CNI when argv[0] is "flannel")
# Extract to a separate copy named flannel.exe in the CNI bin dir.
if (-not (Test-Path $FlannetCniPath)) {
    $tarPath = "$env:TEMP\flannel-windows.tar.gz"
    $url = "https://github.com/flannel-io/flannel/releases/download/$FlannelVersion/flannel-$FlannelVersion-windows-amd64.tar.gz"
    Write-Log "04-k3s-agent: Downloading flannel Windows package for CNI plugin"
    curl.exe -fsSL -L -o $tarPath $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: flannel Windows tar.gz from $url" }
    # Extract - the archive contains dist/flanneld.exe; copy it as flannel.exe in CNI dir
    $extractDir = "$env:TEMP\flannel-cni-extract"
    $null = New-Item -ItemType Directory -Force -Path $extractDir
    tar.exe -xzf $tarPath -C $extractDir 2>&1 | Out-Null
    # Find the extracted exe (may be dist/flanneld.exe or similar)
    $extracted = Get-ChildItem $extractDir -Recurse -Filter '*.exe' | Select-Object -First 1
    if (-not $extracted) { throw "Could not find .exe in flannel Windows tar.gz" }
    Copy-Item $extracted.FullName $FlannetCniPath -Force
    Remove-Item $tarPath, $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "04-k3s-agent: flannel CNI plugin installed from $($extracted.Name)"
} else { Write-Log "04-k3s-agent: flannel CNI plugin already present" }

# hns.psm1 — required by start-network.ps1 (provides New-HnsNetwork, Get-HnsNetwork)
# Source: Microsoft SDN toolkit (https://github.com/microsoft/SDN)
$HnsPsmPath = "$KDir\hns.psm1"
if (-not (Test-Path $HnsPsmPath)) {
    $url = 'https://raw.githubusercontent.com/microsoft/SDN/master/Kubernetes/windows/hns.psm1'
    curl.exe -fsSL -o $HnsPsmPath $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: hns.psm1 from $url" }
    Write-Log '04-k3s-agent: hns.psm1 downloaded'
} else { Write-Log '04-k3s-agent: hns.psm1 already present' }

# host-local IPAM from containernetworking/plugins
if (-not (Test-Path $HostLocalPath)) {
    $tgz = "$env:TEMP\cni-plugins.tgz"
    $url = 'https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-windows-amd64-v1.5.1.tgz'
    curl.exe -fsSL -L -o $tgz $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: cni-plugins" }
    tar.exe -xzf $tgz -C $CniBinDir 2>&1 | Out-Null
    Remove-Item $tgz -Force -ErrorAction SilentlyContinue
    Write-Log "04-k3s-agent: host-local.exe installed"
} else { Write-Log "04-k3s-agent: host-local.exe already present" }

# ---------------------------------------------------------------------------
# Write CNI conflist for flannel -> win-bridge delegation
# containerd reads this from CniConfDir when creating pod sandboxes.
# ---------------------------------------------------------------------------
@"
{
  "name": "cbr0",
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "flannel",
      "delegate": {
        "type": "win-bridge",
        "dns": {
          "Nameservers": ["$ClusterDnsIp"],
          "Search":      ["svc.cluster.local", "cluster.local"]
        },
        "policies": [
          {
            "Name": "EndpointPolicy",
            "Value": {
              "Type": "OutBoundNAT",
              "ExceptionList": ["$ClusterCidr", "$ServiceCidr"]
            }
          },
          {
            "Name": "EndpointPolicy",
            "Value": { "Type": "ROUTE", "DestinationPrefix": "$ServiceCidr", "NeedEncap": true }
          },
          {
            "Name": "EndpointPolicy",
            "Value": { "Type": "ROUTE", "DestinationPrefix": "$ClusterCidr",  "NeedEncap": true }
          }
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": { "portMappings": true }
    }
  ]
}
"@ | Set-Content -Path "$CniConfDir\10-flannel.conflist" -Encoding ascii
Write-Log "04-k3s-agent: CNI conflist written"

# ---------------------------------------------------------------------------
# Update containerd config.toml to add the [cni] plugin section
# 03-containerd.ps1 stored the config at C:\containerd\config\config.toml
# ---------------------------------------------------------------------------
$containerdConf = 'C:\containerd\config\config.toml'
if (Test-Path $containerdConf) {
    $cfg = Get-Content $containerdConf -Raw
    if ($cfg -notmatch [regex]::Escape('[plugins."io.containerd.grpc.v1.cri".cni]')) {
        $cfg += "`n[plugins.`"io.containerd.grpc.v1.cri`".cni]`n  bin_dir  = `"$($CniBinDir -replace '\\','\\\\')`"`n  conf_dir = `"$($CniConfDir -replace '\\','\\\\')`"`n"
        Set-Content -Path $containerdConf -Value $cfg -Encoding ascii
        Write-Log "04-k3s-agent: Added [cni] section to containerd config.toml"
        Restart-Service containerd -Force
        Start-Sleep -Seconds 5
        Write-Log "04-k3s-agent: containerd restarted"
    } else {
        Write-Log "04-k3s-agent: containerd config.toml already has [cni] section"
    }
} else {
    Write-Log "04-k3s-agent: WARNING - $containerdConf not found; containerd may not pick up CNI config"
}

# ---------------------------------------------------------------------------
# Add C:\k to system PATH
# ---------------------------------------------------------------------------
$mp = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
if ($mp -notlike "*$KDir*") {
    [Environment]::SetEnvironmentVariable('PATH', "$mp;$KDir", 'Machine')
    $env:PATH = "$env:PATH;$KDir"
}

# ---------------------------------------------------------------------------
# Write kube-proxy startup script
# kube-proxy kernelspace mode needs --source-vip = the gateway IP of the cbr0
# HNS L2Bridge network, which flanneld creates on first run.  We cannot know
# this IP at Packer build time, so we wrap kube-proxy in a PowerShell script
# that waits for cbr0 to appear, then extracts the gateway IP dynamically.
# This script is registered as a SYSTEM scheduled task triggered at startup.
# ---------------------------------------------------------------------------
@"
# C:\k\start-kube-proxy.ps1 - DO NOT EDIT (generated by 04-k3s-agent.ps1)
`$ErrorActionPreference = 'Continue'
`$Log = 'C:\k\kube-proxy.log'
function KpLog(`$m) { "[`$(Get-Date -f HH:mm:ss)] `$m" | Tee-Object -FilePath `$Log -Append }

KpLog 'start-kube-proxy: waiting for cbr0 HNS network (created by StartNetwork task)...'
`$deadline = (Get-Date).AddSeconds(300)
`$hnsNet = `$null
while ((Get-Date) -lt `$deadline) {
    try { `$hnsNet = Get-HnsNetwork | Where-Object { `$_.Name -eq 'cbr0' } } catch {}
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
Write-Log "04-k3s-agent: kube-proxy startup script written"

# ---------------------------------------------------------------------------
# Write start-network.ps1
# Replaces flanneld: waits for k3s to assign pod CIDR, creates cbr0 HNS
# L2Bridge network, writes CNI conflist with actual CIDR, adds Linux routes.
# Registered as StartNetwork scheduled task (SYSTEM, at startup).
# ---------------------------------------------------------------------------
# NOTE: Single-quoted @'...'@ so the nested @"..."@ writing the CNI conflist
# does not prematurely close the outer block. Build-time values are injected
# via -replace after the literal string is evaluated.
# ---------------------------------------------------------------------------
(@'
# C:\k\start-network.ps1 - Windows pod network setup (generated by 04-k3s-agent.ps1)
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
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "win-bridge",
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

# Import HNS PowerShell cmdlets (New-HnsNetwork, Get-HnsNetwork)
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
Write-Log "04-k3s-agent: start-network.ps1 written"

# ---------------------------------------------------------------------------
# Register kubelet as a Windows service.
# Uses a KubeletConfiguration file for settings that are no longer accepted
# as CLI flags in kubelet v1.32 (clusterDNS, clusterDomain, resolvConf,
# containerRuntimeEndpoint).
# ---------------------------------------------------------------------------
$nodeName = $env:COMPUTERNAME.ToLower()
$nodeIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notmatch '^(169\.254|127\.)' -and
        $_.PrefixOrigin -ne 'WellKnown'
    } |
    Sort-Object -Property InterfaceIndex |
    Select-Object -First 1).IPAddress
Write-Log "04-k3s-agent: Windows node IP = $nodeIp"

# Write KubeletConfiguration
@"
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
clusterDNS:
  - "$ClusterDnsIp"
clusterDomain: "cluster.local"
resolvConf: ""
containerRuntimeEndpoint: "npipe:////./pipe/containerd-containerd"
registerNode: true
"@ | Set-Content -Path "$KDir\kubelet-config.yaml" -Encoding ascii
Write-Log "04-k3s-agent: kubelet-config.yaml written"

$kubeletSvc = 'kubelet'
$existing = Get-Service $kubeletSvc -ErrorAction SilentlyContinue
if ($existing) {
    Stop-Service $kubeletSvc -Force -ErrorAction SilentlyContinue
    $null = sc.exe delete $kubeletSvc; Start-Sleep 2
}

$kubeletBin = "`"$KubeletPath`" " +
    "--v=2 --windows-service " +
    "--hostname-override=$nodeName " +
    "--node-ip=$nodeIp " +
    "--kubeconfig=`"$kubeconfigPath`" " +
    "--config=`"$KDir\kubelet-config.yaml`" " +
    "--root-dir=C:\var\lib\kubelet " +
    "--cert-dir=`"$PkiDir`" " +
    "--pod-infra-container-image=mcr.microsoft.com/oss/kubernetes/pause:3.9 " +
    "--register-with-taints=os=windows:NoSchedule " +
    "--node-labels=kubernetes.io/os=windows " +
    "--cloud-provider=`"`""

$null = New-Service -Name $kubeletSvc `
    -BinaryPathName $kubeletBin `
    -DisplayName 'Kubernetes kubelet' `
    -StartupType Automatic `
    -Description 'Kubernetes node agent — registers this Windows node with the k3s control plane'
Write-Log "04-k3s-agent: kubelet service registered"

# ---------------------------------------------------------------------------
# Register StartNetwork and StartKubeProxy as scheduled tasks (SYSTEM, startup)
# ---------------------------------------------------------------------------
foreach ($taskDef in @(
    @{ Name='StartNetwork';   Script='start-network.ps1';   Restart=3 },
    @{ Name='StartKubeProxy'; Script='start-kube-proxy.ps1'; Restart=5 }
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
    Write-Log "04-k3s-agent: $($taskDef.Name) scheduled task registered"
}

# ---------------------------------------------------------------------------
# Firewall rules for Kubernetes
# ---------------------------------------------------------------------------
Write-Log "04-k3s-agent: Configuring firewall rules..."
$fwRules = @(
    @{ N='k8s-kubelet';      P='TCP'; Port=10250;        D='kubelet API' },
    @{ N='k8s-nodeport-tcp'; P='TCP'; Port='30000-32767'; D='NodePort TCP' },
    @{ N='k8s-nodeport-udp'; P='UDP'; Port='30000-32767'; D='NodePort UDP' },
    @{ N='WinRM-HTTP';       P='TCP'; Port=5985;          D='WinRM' }
)
foreach ($r in $fwRules) {
    if (-not (Get-NetFirewallRule -DisplayName $r.N -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $r.N -Direction Inbound -Action Allow `
            -Protocol $r.P -LocalPort $r.Port -Description $r.D | Out-Null
        Write-Log "04-k3s-agent: Firewall rule added: $($r.N)"
    }
}

Write-Log "04-k3s-agent: Installation complete."
Write-Log "04-k3s-agent: Boot sequence:"
Write-Log "04-k3s-agent:   kubelet service starts -> registers Windows node with k3s"
Write-Log "04-k3s-agent:   StartNetwork task -> waits for pod CIDR -> creates cbr0 HNS -> Linux routes"
Write-Log "04-k3s-agent:   StartKubeProxy task -> waits for cbr0 -> starts kube-proxy kernelspace"
Write-Log '04-k3s-agent: Done'
