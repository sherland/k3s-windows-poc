# =============================================================================
# scripts/Export-KubeConfig.ps1
# Phase 5 — Pull kubeconfig from the Linux VM, patch the server IP, and write
# output/kubeconfig.yaml + output/cluster-info.txt.
# Idempotent: re-runs always refresh the kubeconfig (IPs can change after reboot).
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Helpers.ps1"
. "$PSScriptRoot\..\config\variables.ps1"

$KubeconfigPath  = Join-Path $script:OutputDir 'kubeconfig.yaml'
$ClusterInfoPath = Join-Path $script:OutputDir 'cluster-info.txt'
$SshKeyPath      = Join-Path $script:OutputDir 'linux-build-key'

# ---------------------------------------------------------------------------
function Get-CurrentLinuxIP {
    $vm = Get-VM -Name $script:LinuxVMName -ErrorAction SilentlyContinue
    Assert-True ($null -ne $vm) "Linux VM '$($script:LinuxVMName)' not found"
    Assert-True ($vm.State -eq 'Running') "Linux VM '$($script:LinuxVMName)' is not Running"
    return Get-VMIPAddress -VMName $script:LinuxVMName -TimeoutSec 60
}

function Get-CurrentWindowsIP {
    $vm = Get-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') { return $null }
    return Get-VMIPAddress -VMName $script:WindowsVMName -TimeoutSec 30
}

# ---------------------------------------------------------------------------
function Test-Phase5Complete {
    if (-not (Test-PhaseComplete 'phase5')) { return $false }
    if (-not (Test-Path $KubeconfigPath))   { return $false }
    # Verify kubectl can reach the cluster
    try {
        $env:KUBECONFIG = $KubeconfigPath
        kubectl cluster-info --request-timeout=5s 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Assert-Phase5Complete {
    Write-Step "Verifying Phase 5 (kubeconfig)..."

    Assert-True (Test-Path $KubeconfigPath) "kubeconfig not found at $KubeconfigPath"

    # Test TCP reachability first (avoids kubectl hanging on a dropped SYN)
    $linuxIp = (Get-Content (Join-Path $script:OutputDir 'linux-vm-ip.txt') -Raw).Trim()
    $tcpOk = $false
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $ar  = $tcp.BeginConnect($linuxIp, 6443, $null, $null)
        $tcpOk = $ar.AsyncWaitHandle.WaitOne(8000)   # 8 s connect timeout
        $tcp.Close()
    } catch {}
    Assert-True $tcpOk "Cannot reach k3s API at ${linuxIp}:6443 (TCP timeout). k3s may still be starting." `
        "Wait 30s then re-run: .\scripts\Main.ps1 -StartFromPhase 5"

    $env:KUBECONFIG = $KubeconfigPath
    $result = kubectl cluster-info --insecure-skip-tls-verify --request-timeout=15s 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "kubectl cluster-info failed: $result" `
        "Check that the Linux VM is running and reachable. Re-run Export-KubeConfig.ps1 -Force"

    Write-Success "Phase 5 OK — kubeconfig is valid and cluster is reachable"
}

# ---------------------------------------------------------------------------
function Invoke-Phase5 {
    Write-PhaseHeader '5' 'Export kubeconfig + cluster-info'

    Initialize-OutputDir $script:OutputDir

    $linuxIp  = Get-CurrentLinuxIP
    $windowsIp = Get-CurrentWindowsIP

    Write-Step "Linux VM IP:   $linuxIp"
    Write-Step "Windows VM IP: $(if ($windowsIp) { $windowsIp } else { '(not running)' })"

    # Update stored IP file
    Set-Content -Path (Join-Path $script:OutputDir 'linux-vm-ip.txt') -Value $linuxIp.Trim()

    # Retrieve kubeconfig via SCP
    Invoke-Step 'Copy kubeconfig from Linux VM' {
        $remotePath = '/home/k8sadmin/k3s.yaml'

        # If the file isn't there yet (VM just booted), wait for it
        Wait-Until -TimeoutSec 60 -PollSec 5 -Description 'kubeconfig to appear on Linux VM' -Condition {
            $check = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
                         -o ConnectTimeout=5 -i $SshKeyPath `
                         "$($script:LinuxAdminUser)@$linuxIp" `
                         "test -f $remotePath && echo ok" 2>&1
            return ($check -eq 'ok')
        }

        Copy-SshFile -HostIp $linuxIp -User $script:LinuxAdminUser `
                     -KeyPath $SshKeyPath `
                     -RemotePath $remotePath `
                     -LocalPath $KubeconfigPath
    }

    # Patch server address (k3s writes 127.0.0.1 in the kubeconfig)
    Invoke-Step 'Patch kubeconfig server address' {
        $cfg = Get-Content $KubeconfigPath -Raw
        $cfg = $cfg -replace 'server:\s*https://127\.0\.0\.1:6443', "server: https://${linuxIp}:6443"
        $cfg = $cfg -replace 'name:\s*default', 'name: k8s-hyper-v'
        $cfg = $cfg -replace 'cluster:\s*default', 'cluster: k8s-hyper-v'
        $cfg = $cfg -replace 'user:\s*default', 'user: k8s-hyper-v'
        $cfg = $cfg -replace 'context:\s*default', 'context: k8s-hyper-v'
        $cfg = $cfg -replace 'current-context:\s*default', 'current-context: k8s-hyper-v'
        # k3s cert is issued for 127.0.0.1; skip TLS verification when connecting via LAN IP.
        # Replace certificate-authority-data line with insecure-skip-tls-verify: true
        $cfg = $cfg -replace '(\s+)certificate-authority-data:\s*\S+', '$1insecure-skip-tls-verify: true'
        Set-Content -Path $KubeconfigPath -Value $cfg -NoNewline
        Write-Step "Server address patched to https://${linuxIp}:6443 (TLS verify skipped)"
    }

    # Write cluster-info.txt
    Invoke-Step 'Write cluster-info.txt' {
        $winLine = if ($windowsIp) { $windowsIp } else { 'VM not running' }
        $info = @"
=============================================================================
  Kubernetes Cluster — Hyper-V (Windows 11 host)
  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
=============================================================================

NODES
  Linux master  : $linuxIp   ($($script:LinuxVMName))
  Windows worker: $winLine   ($($script:WindowsVMName))

KUBECTL ACCESS
  Set environment variable:
    `$env:KUBECONFIG = "$KubeconfigPath"

  Or pass explicitly:
    kubectl --kubeconfig "$KubeconfigPath" get nodes -o wide

  Context name: k8s-hyper-v

LINUX VM SSH
  ssh -i "$SshKeyPath" $($script:LinuxAdminUser)@$linuxIp

WINDOWS VM (PowerShell remoting)
  `$cred = Get-Credential Administrator   # password in config/variables.ps1
  Enter-PSSession -ComputerName $winLine -Credential `$cred -Authentication Basic

CREDENTIALS
  See: config/variables.ps1
  Linux admin : $($script:LinuxAdminUser)
  Windows admin: Administrator

USEFUL COMMANDS
  kubectl get nodes -o wide
  kubectl get pods --all-namespaces
  kubectl describe node $($script:WindowsVMName.ToLower())

=============================================================================
"@
        Set-Content -Path $ClusterInfoPath -Value $info
    }

    Assert-Phase5Complete

    Write-Host ''
    Write-Host '  kubeconfig : ' -NoNewline; Write-Host $KubeconfigPath -ForegroundColor Yellow
    Write-Host '  cluster info: ' -NoNewline; Write-Host $ClusterInfoPath -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Usage:' -ForegroundColor Cyan
    Write-Host "    `$env:KUBECONFIG = `"$KubeconfigPath`"" -ForegroundColor White
    Write-Host '    kubectl get nodes -o wide' -ForegroundColor White
    Write-Host ''

    Set-PhaseComplete 'phase5'
    Write-PhaseDone '5'
}

# ---------------------------------------------------------------------------
# Entry point — Phase 5 always refreshes (IPs may change after reboot)
# ---------------------------------------------------------------------------
if ($Force) { Reset-PhaseComplete 'phase5' }

if (-not $Force -and (Test-Phase5Complete)) {
    Write-Success 'Phase 5 already complete — skipping (use -Force to refresh kubeconfig)'
} else {
    Invoke-Phase5
}
