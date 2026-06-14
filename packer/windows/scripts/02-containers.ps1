# =============================================================================
# packer/windows/scripts/02-containers.ps1
# Install Windows features: Containers + Hyper-V (for Hyper-V isolation).
# A reboot is required - Packer's windows-restart provisioner handles it.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Msg) Write-Host "[$(Get-Date -f HH:mm:ss)] $Msg" }

Write-Log '02-containers: Installing Containers and Hyper-V features'

$featuresToInstall = @('Containers', 'Microsoft-Hyper-V')

foreach ($feature in $featuresToInstall) {
    $state = (Get-WindowsOptionalFeature -FeatureName $feature -Online -ErrorAction SilentlyContinue).State
    if ($state -eq 'Enabled') {
        Write-Log "02-containers: $feature already enabled - skipping"
        continue
    }

    Write-Log "02-containers: Enabling $feature..."
    Enable-WindowsOptionalFeature -FeatureName $feature -Online -NoRestart -All | Out-Null
    Write-Log "02-containers: $feature enabled (pending reboot)"
}

# Check if a reboot is actually needed
$pending = Get-WindowsOptionalFeature -Online |
           Where-Object { $featuresToInstall -contains $_.FeatureName -and $_.State -ne 'Enabled' }

if ($pending) {
    Write-Log '02-containers: Reboot required to complete feature installation'
    # Signal Packer windows-restart provisioner by exiting cleanly;
    # the restart_check_command in the HCL will confirm features are enabled after reboot.
    Exit 0
} else {
    Write-Log '02-containers: All features already active - no reboot needed'
}
