# =============================================================================
# scripts/Main.ps1
# Orchestrator — runs all phases in order to build the Hyper-V Kubernetes cluster.
#
# USAGE
#   # Full run (skips already-complete phases):
#   .\scripts\Main.ps1
#
#   # Resume from a specific phase:
#   .\scripts\Main.ps1 -StartFromPhase 4
#
#   # Force re-run of specific phases:
#   .\scripts\Main.ps1 -ForcePhase 2,4
#
#   # Only run health checks without changing anything:
#   .\scripts\Main.ps1 -HealthCheckOnly
#
#   # Force complete re-run of everything:
#   .\scripts\Main.ps1 -ForcePhase 0,1,2,3,4,5,6
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [int]$StartFromPhase = 0,
    [int[]]$ForcePhase   = @(),
    [switch]$HealthCheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot

. "$ScriptDir\Helpers.ps1"
. "$ScriptDir\..\config\variables.ps1"

# ---------------------------------------------------------------------------
# Phase registry
# ---------------------------------------------------------------------------
$Phases = @(
    @{ Number = 0; Name = 'Host Prerequisites';          Script = 'Install-Prerequisites.ps1' },
    @{ Number = 1; Name = 'Hyper-V External vSwitch';    Script = 'New-HyperVSwitch.ps1' },
    @{ Number = 2; Name = 'Build Linux VM (k3s server)'; Script = 'Build-LinuxVM.ps1' },
    @{ Number = 3; Name = 'Download Windows ISO';        Script = 'Build-WindowsVM.ps1' },   # phases 3+4 in same script
    @{ Number = 4; Name = 'Build Windows VM (k3s agent)'; Script = $null },                   # driven by above
    @{ Number = 5; Name = 'Export kubeconfig';            Script = 'Export-KubeConfig.ps1' },
    @{ Number = 6; Name = 'Join Windows node';             Script = 'Join-WindowsNode.ps1' }
)

# ---------------------------------------------------------------------------
function Write-Banner {
    $line = '=' * 72
    Write-Host $line -ForegroundColor Blue
    Write-Host '  Hyper-V Kubernetes Cluster Builder' -ForegroundColor Blue
    Write-Host '  Linux master (k3s server)  +  Windows worker (k3s agent)' -ForegroundColor Blue
    Write-Host $line -ForegroundColor Blue
    Write-Host "  Host:   $env:COMPUTERNAME   ($([System.Environment]::OSVersion.VersionString))" -ForegroundColor Gray
    Write-Host "  Repo:   $script:RepoRoot" -ForegroundColor Gray
    Write-Host "  Start:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
    Write-Host $line -ForegroundColor Blue
    Write-Host ''
}

# ---------------------------------------------------------------------------
function Get-OkColor {
    param([bool]$Ok)
    if ($Ok) { return 'Green' } else { return 'Red' }
}

function Invoke-HealthCheck {
    Write-PhaseHeader 'HC' 'Health Check — verifying all phases'

    $kubeconfig = Join-Path $script:OutputDir 'kubeconfig.yaml'

    # Phase 0: binaries
    foreach ($bin in @('packer', 'kubectl', 'ssh')) {
        $ok    = $null -ne (Get-Command $bin -ErrorAction SilentlyContinue)
        $label = if ($ok) { 'OK' } else { 'MISSING' }
        Write-Host "  Phase 0 — $bin on PATH: $label" -ForegroundColor (Get-OkColor $ok)
    }

    $hvSvc   = Get-Service -Name 'vmms' -ErrorAction SilentlyContinue
    $hvOk    = $null -ne $hvSvc
    $hvLabel = if ($hvOk) { 'Enabled' } else { 'Disabled' }
    Write-Host "  Phase 0 — Hyper-V: $hvLabel" -ForegroundColor (Get-OkColor $hvOk)

    # Phase 1: vSwitch
    $sw    = Get-VMSwitch -Name $script:vSwitchName -ErrorAction SilentlyContinue
    $swOk  = $null -ne $sw -and $sw.SwitchType -eq 'External'
    $swLabel = if ($sw) { [string]$sw.SwitchType } else { 'NOT FOUND' }
    Write-Host "  Phase 1 — vSwitch '$($script:vSwitchName)': $swLabel" -ForegroundColor (Get-OkColor $swOk)

    # Phase 2: Linux VM
    $linuxVm    = Get-VM -Name $script:LinuxVMName -ErrorAction SilentlyContinue
    $linuxState = if ($linuxVm) { [string]$linuxVm.State } else { 'NOT FOUND' }
    $linuxOk    = $linuxState -eq 'Running'
    Write-Host "  Phase 2 — Linux VM '$($script:LinuxVMName)': $linuxState" -ForegroundColor (Get-OkColor $linuxOk)

    # Phase 4: Windows VM
    $winVm    = Get-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
    $winState = if ($winVm) { [string]$winVm.State } else { 'NOT FOUND' }
    $winOk    = $winState -eq 'Running'
    Write-Host "  Phase 4 — Windows VM '$($script:WindowsVMName)': $winState" -ForegroundColor (Get-OkColor $winOk)

    if ($winVm) {
        $nestedVirt = (Get-VMProcessor -VMName $script:WindowsVMName).ExposeVirtualizationExtensions
        Write-Host "  Phase 4 — Nested virt on Windows VM: $nestedVirt" -ForegroundColor (Get-OkColor $nestedVirt)
    }

    # Phase 5/6: kubeconfig + cluster
    $kcExists = Test-Path $kubeconfig
    Write-Host "  Phase 5 — kubeconfig exists: $kcExists" -ForegroundColor (Get-OkColor $kcExists)

    if ($kcExists) {
        $env:KUBECONFIG = $kubeconfig
        $null = kubectl cluster-info --request-timeout=8s 2>$null
        $reachable = $LASTEXITCODE -eq 0
        Write-Host "  Phase 5 — cluster reachable: $reachable" -ForegroundColor (Get-OkColor $reachable)

        if ($reachable) {
            Write-Host ''
            Write-Host '  kubectl get nodes:' -ForegroundColor Cyan
            kubectl get nodes -o wide 2>$null | ForEach-Object { Write-Host "    $_" }
        } else {
            Write-Host '  NOTE: VMs may be rebooting (post-Packer deferred setup). Cluster will recover.' -ForegroundColor Yellow
        }
    }

    Write-Host ''
}

# ---------------------------------------------------------------------------
function Invoke-Phase {
    param(
        [int]$PhaseNum,
        [bool]$Force
    )

    if ($PhaseNum -lt $StartFromPhase) {
        Write-Host "  [SKIP] Phase $PhaseNum — before start phase ($StartFromPhase)" -ForegroundColor Gray
        return
    }

    switch ($PhaseNum) {
        0 { & "$ScriptDir\Install-Prerequisites.ps1" -Force:$Force }
        1 { & "$ScriptDir\New-HyperVSwitch.ps1"      -Force:$Force }
        2 { & "$ScriptDir\Build-LinuxVM.ps1"          -Force:$Force }
        3 { & "$ScriptDir\Build-WindowsVM.ps1" -Force:$Force }  # ISO download (phase3 sentinel)
        4 { & "$ScriptDir\Build-WindowsVM.ps1" -Force:$Force }  # Packer build (phase4 sentinel)
        5 { & "$ScriptDir\Export-KubeConfig.ps1" -Force:$Force }
        6 { & "$ScriptDir\Join-WindowsNode.ps1"    -Force:$Force }
    }
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
Write-Banner

if ($HealthCheckOnly) {
    Invoke-HealthCheck
    exit 0
}

$startTime = Get-Date

# Pre-flight: disk space on the repo drive
Assert-DiskSpace -Path $script:RepoRoot -MinimumGB 50

# Ensure output dir exists early (sentinels and logs go there)
Initialize-OutputDir $script:OutputDir

# Run phases
$phasesToRun = @(0, 1, 2, 3, 4, 5, 6)  # 3=ISO download, 4=Packer build, 5=export kubeconfig, 6=join Windows node

foreach ($phaseNum in $phasesToRun) {
    $forced = $ForcePhase -contains $phaseNum
    try {
        Invoke-Phase -PhaseNum $phaseNum -Force $forced
    }
    catch {
        Write-Host ''
        Write-Host ('=' * 72) -ForegroundColor Red
        Write-Host "  FATAL ERROR in Phase $phaseNum" -ForegroundColor Red
        Write-Host "  $_" -ForegroundColor Red
        Write-Host ''
        Write-Host '  To resume from this phase after fixing the issue:' -ForegroundColor Yellow
        Write-Host "    .\scripts\Main.ps1 -StartFromPhase $phaseNum" -ForegroundColor White
        Write-Host ''
        Write-Host '  Packer log (if applicable):' -ForegroundColor Yellow
        Write-Host "    $script:OutputDir\packer-linux.log" -ForegroundColor Gray
        Write-Host "    $script:OutputDir\packer-windows.log" -ForegroundColor Gray
        Write-Host ('=' * 72) -ForegroundColor Red
        exit 1
    }
}

# Final health check
Invoke-HealthCheck

$elapsed = (Get-Date) - $startTime
Write-Host ('=' * 72) -ForegroundColor Green
Write-Host "  ALL PHASES COMPLETE" -ForegroundColor Green
Write-Host "  Total time: $([math]::Round($elapsed.TotalMinutes, 1)) minutes" -ForegroundColor Green
Write-Host ''
Write-Host "  Your cluster is ready. Set:" -ForegroundColor Cyan
Write-Host "    `$env:KUBECONFIG = `"$(Join-Path $script:OutputDir 'kubeconfig.yaml')`"" -ForegroundColor White
Write-Host "  Then run: kubectl get nodes -o wide" -ForegroundColor White
Write-Host ''
Write-Host "  Full connection details: $(Join-Path $script:OutputDir 'cluster-info.txt')" -ForegroundColor Gray
Write-Host ('=' * 72) -ForegroundColor Green
