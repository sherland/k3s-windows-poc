# =============================================================================
# packer/windows/scripts/05-firstboot-setup.ps1
# Bake the per-node first-boot self-configuration mechanism into the base image.
#
# Creates:
#   C:\k8s-firstboot.ps1     — script that reads C:\k8s-node-config.json
#                              and configures this node (kubeconfigs, kubelet
#                              service registration, hostname, reboot).
#   C:\k8s-firstboot.pending — existence signals that first-boot hasn't run yet
#   ScheduledTask: k8s-firstboot — SYSTEM, AtStartup, runs once
#
# C:\k8s-node-config.json is injected offline (via Mount-VHD / Dismount-VHD)
# by Join-Nodes.ps1 BEFORE the VM is started for the first time.
#
# JSON schema:
# {
#   "hostname":             "k8s-win-01",
#   "k3sServerIP":          "192.168.1.10",
#   "nodeToken":            "<k3s node-token>",
#   "osVersion":            "2025",
#   "kubeconfigB64":        "<base64 kubeconfig>",
#   "flannelKubeconfigB64": "<base64 flannel kubeconfig>"
# }
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Msg) Write-Host "[$(Get-Date -f HH:mm:ss)] $Msg" }

Write-Log "05-firstboot-setup: Creating C:\k8s-firstboot.ps1 ..."

# ---------------------------------------------------------------------------
# Write C:\k8s-firstboot.ps1
# ---------------------------------------------------------------------------
@'
# =============================================================================
# C:\k8s-firstboot.ps1
# Runs once at first boot of a Windows worker node differencing-disk clone.
# Reads C:\k8s-node-config.json (injected offline by Join-Nodes.ps1).
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Log = 'C:\k8s-firstboot.log'
function FbLog($m) { "[$(Get-Date -f HH:mm:ss)] $m" | Tee-Object -FilePath $Log -Append }

$PendingMarker = 'C:\k8s-firstboot.pending'
$ConfigFile    = 'C:\k8s-node-config.json'

if (-not (Test-Path $PendingMarker)) {
    FbLog 'k8s-firstboot: pending marker not found — skipping (already ran or not expected)'
    exit 0
}

if (-not (Test-Path $ConfigFile)) {
    FbLog "k8s-firstboot: ERROR - $ConfigFile not found. Was Join-Nodes.ps1 offline injection done?"
    exit 1
}

FbLog 'k8s-firstboot: reading node config...'
$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$Hostname  = $cfg.hostname
$KDir      = 'C:\k'
$KubeconfigPath        = "$KDir\kubeconfig.yaml"
$FlannelKubeconfigPath = "$KDir\flannel-kubeconfig.yaml"
$KubeletPath           = "$KDir\kubelet.exe"
$PkiDir                = "$KDir\pki"

FbLog "k8s-firstboot: hostname=$Hostname  k3sServerIP=$($cfg.k3sServerIP)"

# ---------------------------------------------------------------------------
# Write kubeconfigs
# ---------------------------------------------------------------------------
[System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String($cfg.kubeconfigB64)) |
    Set-Content -Path $KubeconfigPath -Encoding UTF8
FbLog "k8s-firstboot: $KubeconfigPath written"

[System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String($cfg.flannelKubeconfigB64)) |
    Set-Content -Path $FlannelKubeconfigPath -Encoding UTF8
FbLog "k8s-firstboot: $FlannelKubeconfigPath written"

# Restrict kubeconfig permissions to SYSTEM + Administrators
foreach ($f in @($KubeconfigPath, $FlannelKubeconfigPath)) {
    $acl = Get-Acl $f
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM',         'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('Administrators', 'FullControl', 'Allow')))
    Set-Acl -Path $f -AclObject $acl
}

# ---------------------------------------------------------------------------
# Determine local node IP (first non-loopback, non-APIPA IPv4)
# ---------------------------------------------------------------------------
$nodeIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notmatch '^(169\.254|127\.)' -and
        $_.PrefixOrigin -ne 'WellKnown'
    } |
    Sort-Object -Property InterfaceIndex |
    Select-Object -First 1).IPAddress
FbLog "k8s-firstboot: node IP = $nodeIp"

# ---------------------------------------------------------------------------
# Register kubelet Windows service
# kubelet v1.32 cluster-level settings are in kubelet-config.yaml (written
# by 04-install-k8s-binaries.ps1). We add --hostname-override and --node-ip
# here because they are per-node values.
# ---------------------------------------------------------------------------
$kubeletSvc = 'kubelet'
$existing   = Get-Service $kubeletSvc -ErrorAction SilentlyContinue
if ($existing) {
    Stop-Service $kubeletSvc -Force -ErrorAction SilentlyContinue
    $null = sc.exe delete $kubeletSvc; Start-Sleep -Seconds 2
}

# NOTE: --cloud-provider was removed in k8s 1.33 (KEP-2395 cloud-provider extraction).
# NOTE: --pod-infra-container-image was removed in k8s 1.31; use KubeletConfiguration.podInfraContainerImage instead.
# Both flags cause kubelet v1.33+ to exit immediately with 'unknown flag'.
$kubeletBin = "`"$KubeletPath`" " +
    "--v=2 --windows-service " +
    "--hostname-override=$Hostname " +
    "--node-ip=$nodeIp " +
    "--kubeconfig=`"$KubeconfigPath`" " +
    "--config=`"$KDir\kubelet-config.yaml`" " +
    "--root-dir=C:\var\lib\kubelet " +
    "--cert-dir=`"$PkiDir`" " +
    "--register-with-taints=os=windows:NoSchedule " +
    "--node-labels=kubernetes.io/os=windows"

$null = New-Service -Name $kubeletSvc `
    -BinaryPathName $kubeletBin `
    -DisplayName 'Kubernetes kubelet' `
    -StartupType Automatic `
    -Description 'Kubernetes node agent — registers this Windows node with the k3s control plane'
FbLog 'k8s-firstboot: kubelet service registered'

Start-Service $kubeletSvc
FbLog 'k8s-firstboot: kubelet service started'

# ---------------------------------------------------------------------------
# Clean up — remove pending marker and unregister this task
# ---------------------------------------------------------------------------
Remove-Item $PendingMarker -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'k8s-firstboot' -Confirm:$false -ErrorAction SilentlyContinue
FbLog 'k8s-firstboot: cleanup done'

# ---------------------------------------------------------------------------
# Rename computer and reboot
# (Rename-Computer triggers a reboot; after reboot StartNetwork + StartKubeProxy run)
# ---------------------------------------------------------------------------
FbLog "k8s-firstboot: renaming computer to $Hostname and rebooting..."
Rename-Computer -NewName $Hostname -Force
Restart-Computer -Force
'@ | Set-Content -Path 'C:\k8s-firstboot.ps1' -Encoding UTF8

Write-Log "05-firstboot-setup: C:\k8s-firstboot.ps1 written"

# ---------------------------------------------------------------------------
# Create the pending marker (will be checked at first boot)
# ---------------------------------------------------------------------------
'pending' | Set-Content -Path 'C:\k8s-firstboot.pending' -Encoding ascii
Write-Log "05-firstboot-setup: C:\k8s-firstboot.pending created"

# ---------------------------------------------------------------------------
# Register k8s-firstboot as a scheduled task (SYSTEM, AtStartup, one-shot)
# ---------------------------------------------------------------------------
Unregister-ScheduledTask -TaskName 'k8s-firstboot' -Confirm:$false -ErrorAction SilentlyContinue

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NonInteractive -ExecutionPolicy Bypass -File C:\k8s-firstboot.ps1'
$trigger   = New-ScheduledTaskTrigger -AtStartup
$settings  = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName 'k8s-firstboot' `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

Write-Log "05-firstboot-setup: k8s-firstboot scheduled task registered (SYSTEM, AtStartup)"
Write-Log "05-firstboot-setup: Done."
Write-Log "05-firstboot-setup: First boot sequence:"
Write-Log "  1. k8s-firstboot.ps1 reads C:\k8s-node-config.json"
Write-Log "  2. Writes kubeconfigs, registers kubelet service, starts kubelet"
Write-Log "  3. Renames computer to hostname from config"
Write-Log '  4. Reboots - after reboot: StartNetwork, StartKubeProxy tasks run'
