# =============================================================================
# scripts/New-WindowsNodes.ps1
# Phase 5 — Create Windows node VMs as differencing disks from golden base(s).
#
# Creates each Windows node VM (one per entry in WindowsNodeSpecs), keyed by
# OS version to the correct parent VHDX.  VMs are NOT started here — the k3s
# join token is not yet available (that comes from Bootstrap-ControlPlane).
# Join-Nodes.ps1 (Phase 7) injects k8s-node-config.json offline via Mount-VHD,
# then starts the VMs.
#
# Sentinel per node: node-{vmname}.done
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

# ---------------------------------------------------------------------------
function New-WindowsNode {
    param(
        [string]$NodeName,
        [string]$OSVersion,
        [int]$CPU,
        [int]$RAM
    )

    $nodeSentinel = "node-$NodeName"
    if (-not $Force -and (Test-PhaseComplete $nodeSentinel)) {
        $vm = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
        if ($vm) {
            Write-Success "Windows node '$NodeName' (WS$OSVersion) already created — skipping"
            return
        }
        Reset-PhaseComplete $nodeSentinel
    }

    Write-Step "--- Creating Windows node: $NodeName (WS$OSVersion) ---"

    $parentVhdx = Get-BaseVhdxPath "win${OSVersion}"
    $childVhdx  = Get-NodeVhdxPath $NodeName

    # Remove stale VM
    $stale = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
    if ($stale) {
        Write-Warn "Removing stale VM '$NodeName'..."
        if ($stale.State -ne 'Off') { Stop-VM -Name $NodeName -Force -TurnOff }
        Remove-VM -Name $NodeName -Force
    }
    if (Test-Path $childVhdx) { Remove-Item $childVhdx -Force }

    # Gen 1 for Windows (same as existing build — broadest driver compatibility)
    New-DifferencingNode -VMName $NodeName -ParentVhdxPath $parentVhdx `
        -ChildVhdxPath $childVhdx -CPU $CPU -MemoryMB $RAM `
        -SwitchName $script:vSwitchName -Generation 1

    # NOTE: nested virt is already baked into the base VHDX via Set-VMProcessor
    # on the base VM before it was unregistered.

    Write-Success "Windows node VM '$NodeName' created (NOT started — awaiting k3s token)"
    Set-PhaseComplete $nodeSentinel
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
$osMap = Get-WindowsNodeOSMap

if ($osMap.Count -eq 0) {
    Write-Success 'No Windows nodes configured (WindowsNodeSpecs is empty) — skipping.'
    exit 0
}

Write-PhaseHeader '5' 'Create Windows node VMs (differencing disks, not yet started)'

if ($Force) {
    foreach ($name in $osMap.Keys) { Reset-PhaseComplete "node-$name" }
}

foreach ($name in $osMap.Keys | Sort-Object) {
    $spec = $osMap[$name]
    New-WindowsNode -NodeName $name -OSVersion $spec.OSVersion -CPU $spec.CPU -RAM $spec.RAM
}

Write-PhaseDone '5'
