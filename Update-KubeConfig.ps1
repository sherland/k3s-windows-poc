#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Updates output/kubeconfig.yaml with the current IP of the control-plane VM,
    and fixes the k3s-agent K3S_URL on every Linux worker so they become Ready again.

.DESCRIPTION
    The VMs use DHCP via the external Hyper-V vSwitch, so the control-plane IP
    changes whenever you move between networks (e.g. home <-> office).
    Run this script after moving to a new network to restore kubectl access
    without rebuilding the cluster.

    Two things are updated:
      1. output/kubeconfig.yaml  — the server: URL used by kubectl on the host.
      2. /etc/systemd/system/k3s-agent.service.env on each Linux worker
         — the K3S_URL the agent uses to register with the control plane.
         The k3s-agent service is then restarted so workers return to Ready.

.EXAMPLE
    .\Update-KubeConfig.ps1

.EXAMPLE
    .\Update-KubeConfig.ps1 -Verbose
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Load shared config so we know worker names, SSH key path, etc.
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'config\variables.ps1')
. (Join-Path $PSScriptRoot 'scripts\Helpers.ps1')

$kubeconfigPath = Join-Path $PSScriptRoot 'output\kubeconfig.yaml'

if (-not (Test-Path $kubeconfigPath)) {
    Write-Error "Kubeconfig not found at '$kubeconfigPath'. Has the cluster been built yet?"
}

# ---------------------------------------------------------------------------
# Step 1: get current CP IP from Hyper-V
# ---------------------------------------------------------------------------
$cpVmName = $script:ControlPlaneVMName
Write-Verbose "Querying Hyper-V for current IP of '$cpVmName'..."

$vm = Get-VM -Name $cpVmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Error "VM '$cpVmName' not found. Is Hyper-V running and was the cluster built?"
}
if ($vm.State -ne 'Running') {
    Write-Error "VM '$cpVmName' is not running (state: $($vm.State)). Start the cluster VMs first."
}

$cpIp = ($vm | Get-VMNetworkAdapter).IPAddresses |
    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
    Select-Object -First 1

if (-not $cpIp) {
    Write-Error "Could not determine IPv4 address for '$cpVmName'. The VM may still be booting — wait a moment and retry."
}

# ---------------------------------------------------------------------------
# Step 2: patch kubeconfig
# ---------------------------------------------------------------------------
$null = (Get-Content $kubeconfigPath -Raw) -match 'https://([\d.]+):6443'
$oldIp = $Matches[1]

if ($oldIp -eq $cpIp) {
    Write-Host "Kubeconfig already points to $cpIp — no update needed."
} else {
    Write-Verbose "Replacing '$oldIp' with '$cpIp' in kubeconfig..."
    (Get-Content $kubeconfigPath) -replace 'https://[\d.]+:6443', "https://${cpIp}:6443" |
        Set-Content $kubeconfigPath
    Write-Host "Kubeconfig updated: $oldIp -> $cpIp"
}

# ---------------------------------------------------------------------------
# Step 3: fix K3S_URL on each Linux worker and restart k3s-agent
# ---------------------------------------------------------------------------
# Worker names are lnx-01, lnx-02, … (CP is index 0 in Get-AllLinuxNodeNames)
$allLinux    = Get-AllLinuxNodeNames
$workerNames = $allLinux | Where-Object { $_ -ne $cpVmName }

# Read node token — needed to reconstruct the env file cleanly
$tokenPath = Join-Path $PSScriptRoot 'output\node-token.txt'
if (-not (Test-Path $tokenPath)) {
    Write-Error "Node token not found at '$tokenPath'. Has the cluster been bootstrapped?"
}
$nodeToken = (Get-Content $tokenPath -Raw).Trim()

if ($workerNames.Count -eq 0) {
    Write-Host "No Linux workers configured — skipping agent update."
} else {
    foreach ($workerName in $workerNames) {
        $workerVm = Get-VM -Name $workerName -ErrorAction SilentlyContinue
        if (-not $workerVm) {
            Write-Warning "VM '$workerName' not found — skipping."
            continue
        }
        if ($workerVm.State -ne 'Running') {
            Write-Warning "VM '$workerName' is not running (state: $($workerVm.State)) — skipping."
            continue
        }

        $workerIp = ($workerVm | Get-VMNetworkAdapter).IPAddresses |
            Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
            Select-Object -First 1

        if (-not $workerIp) {
            Write-Warning "Could not get IP for '$workerName' — skipping."
            continue
        }

        Write-Host "Updating k3s-agent on '$workerName' ($workerIp)..."

        # Write the fix as an ASCII shell script to a temp file and scp it over.
        # This avoids CRLF issues and PowerShell quoting complexities when passing
        # sed patterns with special characters over SSH.
        $fixScript = "printf 'K3S_TOKEN=${nodeToken}\nK3S_URL=https://${cpIp}:6443\n' | sudo tee /etc/systemd/system/k3s-agent.service.env && sudo systemctl daemon-reload && sudo systemctl restart --no-block k3s-agent"
        $tmpScript  = Join-Path $env:TEMP 'k3s-fix-agent.sh'
        [System.IO.File]::WriteAllText($tmpScript, $fixScript + "`n", [System.Text.Encoding]::ASCII)

        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
            -i $script:SshKeyPath $tmpScript `
            "$($script:LinuxAdminUser)@${workerIp}:/tmp/k3s-fix-agent.sh" | Out-Null
        Invoke-SshCommand -HostIp $workerIp -User $script:LinuxAdminUser -KeyPath $script:SshKeyPath -Command "bash /tmp/k3s-fix-agent.sh"
        Write-Host "  k3s-agent restarted on '$workerName'."
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Done. Set KUBECONFIG and verify (workers may take ~30 s to become Ready):"
Write-Host "  `$env:KUBECONFIG = `"$kubeconfigPath`""
Write-Host "  kubectl get nodes -o wide"
