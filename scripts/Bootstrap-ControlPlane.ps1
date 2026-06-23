# =============================================================================
# scripts/Bootstrap-ControlPlane.ps1
# Phase 6 — Configure k3s server on the control-plane VM and collect cluster
# credentials for use by worker nodes.
#
# The CP VM is already running (created by New-LinuxNodes). This script:
#   1. Waits for SSH to be available.
#   2. Uploads and executes the k3s server bootstrap scripts.
#   3. Waits for k3s to report Ready.
#   4. Retrieves: node-token, admin kubeconfig, flannel kubeconfig.
#   5. Writes output/node-token.txt and output/linux-vm-ip.txt.
#
# Sentinel: cp-bootstrap.done
#
# NOTE: The k3s binary is already installed in the base image (by Packer).
#       We pass INSTALL_K3S_SKIP_DOWNLOAD=true so the install script only
#       creates the systemd unit — no re-download needed.
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

$CpVMName    = $script:ControlPlaneVMName
$LinuxUser   = $script:LinuxAdminUser
$SshKey      = $script:SshKeyPath
$TokenFile   = Join-Path $script:OutputDir 'node-token.txt'
$LinuxIPFile = Join-Path $script:OutputDir 'linux-vm-ip.txt'

# ---------------------------------------------------------------------------
function Test-CpBootstrapDone {
    if (-not (Test-PhaseComplete 'cp-bootstrap')) { return $false }
    if (-not (Test-Path $TokenFile))              { return $false }
    # Quick connectivity check
    try {
        $cpIp = (Get-Content $LinuxIPFile -Raw).Trim()
        $r = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
                 -o ConnectTimeout=5 -i $SshKey "$LinuxUser@$cpIp" `
                 'systemctl is-active k3s' 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

# ---------------------------------------------------------------------------
function Get-CPIPAndWaitSSH {
    $vm = Get-VM -Name $CpVMName -ErrorAction SilentlyContinue
    Assert-True ($null -ne $vm) "Control-plane VM '$CpVMName' not found. Run New-LinuxNodes.ps1 first."

    if ($vm.State -ne 'Running') {
        Write-Step "Starting CP VM '$CpVMName'..."
        Start-VM -Name $CpVMName
    }

    $ip = Get-VMIPAddress -VMName $CpVMName -TimeoutSec $script:VMBootTimeoutSec
    $null = Assert-True ($ip -ne $null -and $ip -ne '') "Could not get IP for '$CpVMName'"
    Set-Content -Path $LinuxIPFile -Value $ip.Trim()
    Write-Step "CP IP: $ip"

    $null = Wait-Until -TimeoutSec $script:VMBootTimeoutSec -PollSec 10 -Description 'SSH on CP' -Condition {
        $r = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
                 -o ConnectTimeout=5 -i $SshKey "$LinuxUser@$ip" 'echo ok' 2>&1
        return ($LASTEXITCODE -eq 0 -and ($r | Where-Object { $_ -is [string] }) -contains 'ok')
    }
    Write-Success "SSH available on CP ($ip)"
    return $ip
}

# ---------------------------------------------------------------------------
function Invoke-K3sServerBootstrap {
    param([string]$CpIp)

    # Upload the bootstrap scripts (these are the same Packer scripts, reused here)
    $scriptsDir = Join-Path $script:PackerLinuxDir 'scripts'
    Write-Step "Uploading bootstrap scripts to CP..."
    Send-SshFile -HostIp $CpIp -User $LinuxUser -KeyPath $SshKey `
        -LocalPath (Join-Path $scriptsDir '02-k3s-server.sh') -RemotePath '/tmp/02-k3s-server.sh'
    Send-SshFile -HostIp $CpIp -User $LinuxUser -KeyPath $SshKey `
        -LocalPath (Join-Path $scriptsDir '03-export-kubeconfig.sh') -RemotePath '/tmp/03-export-kubeconfig.sh'

    # Run k3s server bootstrap
    # INSTALL_K3S_SKIP_DOWNLOAD=true because the binary is already in the base image
    Write-Step "Running k3s server bootstrap on CP (may take ~5 minutes)..."
    # Cilium and Calico replace k3s embedded flannel — pass 'none' so k3s starts with --flannel-backend=none.
    # All other CNI plugins (flannel, multus, none) keep the configured FlannelBackend (host-gw).
    $flannelBackend = if ($script:CNIPlugin -in @('cilium', 'calico', 'antrea')) { 'none' } else { $script:FlannelBackend }
    Invoke-SshCommand -HostIp $CpIp -User $LinuxUser -KeyPath $SshKey `
        -Command "sudo K3S_VERSION='$($script:K3sVersion)' INSTALL_K3S_SKIP_DOWNLOAD=true FLANNEL_BACKEND='$flannelBackend' bash /tmp/02-k3s-server.sh"

    Write-Step "Exporting kubeconfig and node-token..."
    Invoke-SshCommand -HostIp $CpIp -User $LinuxUser -KeyPath $SshKey `
        -Command 'sudo bash /tmp/03-export-kubeconfig.sh'

    Write-Success "k3s server bootstrap complete"
}

# ---------------------------------------------------------------------------
function Get-ClusterCredentials {
    param([string]$CpIp)

    Write-Step "Retrieving cluster credentials from CP ($CpIp)..."

    # Node token
    $rawToken = Invoke-SshCommand -HostIp $CpIp -User $LinuxUser -KeyPath $SshKey `
        -Command 'cat /home/k8sadmin/node-token 2>/dev/null || sudo cat /var/lib/rancher/k3s/server/node-token' `
        -PassThru
    $token = (($rawToken | Where-Object { $_ -is [string] }) -join "`n").Trim()
    Assert-True ($token.Length -ge 10) "k3s token appears invalid (length $($token.Length))"
    Set-Content -Path $TokenFile -Value $token
    Write-Success "node-token retrieved (length: $($token.Length)) → $TokenFile"

    # Admin kubeconfig (with 127.0.0.1 → CpIp patch)
    $rawKubeconfig = Invoke-SshCommand -HostIp $CpIp -User $LinuxUser -KeyPath $SshKey `
        -Command 'sudo cat /etc/rancher/k3s/k3s.yaml' -PassThru
    $kubeconfigStr = (($rawKubeconfig | Where-Object { $_ -is [string] }) -join "`n").Trim()
    Assert-True ($kubeconfigStr.Length -ge 100) "Admin kubeconfig appears invalid"
    $kubeconfigStr = $kubeconfigStr -replace 'https://127\.0\.0\.1:6443', "https://${CpIp}:6443"
    $kcPath = Join-Path $script:OutputDir 'admin-kubeconfig.yaml'
    Set-Content -Path $kcPath -Value $kubeconfigStr -NoNewline
    Write-Success "Admin kubeconfig retrieved → $kcPath"

    # Flannel ServiceAccount kubeconfig — only created when Flannel is the CNI
    # (i.e. FLANNEL_BACKEND != none). Skipped for Antrea, Cilium, Calico.
    $flannelStr = ''
    if ($script:CNIPlugin -notin @('cilium', 'calico', 'antrea')) {
        $rawFlannel = Invoke-SshCommand -HostIp $CpIp -User $LinuxUser -KeyPath $SshKey `
            -Command 'sudo cat /var/lib/rancher/k3s/server/flannel-kubeconfig.yaml' -PassThru
        $flannelStr = (($rawFlannel | Where-Object { $_ -is [string] }) -join "`n").Trim()
        Assert-True ($flannelStr.Length -ge 100) "Flannel kubeconfig appears invalid"
        $flannelPath = Join-Path $script:OutputDir 'flannel-kubeconfig.yaml'
        Set-Content -Path $flannelPath -Value $flannelStr -NoNewline
        Write-Success "Flannel kubeconfig retrieved → $flannelPath"
    } else {
        Write-Step "  Skipping flannel-kubeconfig (CNI=$($script:CNIPlugin) — no Flannel ServiceAccount token)"
    }

    return @{
        Token            = $token
        ServerIp         = $CpIp
        KubeconfigB64    = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($kubeconfigStr))
        FlannelKcB64     = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($flannelStr))
    }
}

# ---------------------------------------------------------------------------
function Invoke-Phase6 {
    Write-PhaseHeader '6' 'Bootstrap control-plane (k3s server + RBAC + credentials)'

    $cpIp = Get-CPIPAndWaitSSH
    Invoke-K3sServerBootstrap -CpIp $cpIp

    # Wait for k3s to become active
    Wait-Until -TimeoutSec $script:K3sReadyTimeoutSec -PollSec 10 `
        -Description 'k3s to become active on CP' -Condition {
        $r = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
                 -o ConnectTimeout=10 -i $SshKey "$LinuxUser@$cpIp" `
                 'systemctl is-active k3s' 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    Write-Success "k3s is active on CP"

    # Wait for CP node to show Ready
    Wait-Until -TimeoutSec $script:K3sReadyTimeoutSec -PollSec 10 `
        -Description "CP node to become Ready" -Condition {
        $ready = Invoke-SshCommand -HostIp $cpIp -User $LinuxUser -KeyPath $SshKey `
            -Command "sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo 0" -PassThru
        $count = (($ready | Where-Object { $_ -is [string] }) -join '').Trim()
        return ([int]$count -ge 1)
    }
    Write-Success "CP node is Ready"

    Get-ClusterCredentials -CpIp $cpIp | Out-Null

    Set-PhaseComplete 'cp-bootstrap'
    Write-PhaseDone '6'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($Force) { Reset-PhaseComplete 'cp-bootstrap' }

if (Test-CpBootstrapDone) {
    Write-Success 'CP bootstrap already complete — skipping'
} else {
    Invoke-Phase6
}
