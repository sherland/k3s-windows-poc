# =============================================================================
# scripts/Main.ps1
# Orchestrator — runs all phases in order to build the Hyper-V k3s cluster.
#
# USAGE
#   # Full run (skips already-complete phases):
#   .\scripts\Main.ps1
#
#   # Resume from a specific phase:
#   .\scripts\Main.ps1 -StartFromPhase 4
#
#   # Force re-run of specific phases (by number):
#   .\scripts\Main.ps1 -ForcePhase 2,3
#
#   # Force re-run for a single node only (phases 4-7):
#   .\scripts\Main.ps1 -ForceNode k8s-win-01
#
#   # Skip all Windows work (control-plane + Linux workers only):
#   .\scripts\Main.ps1 -SkipWindowsNodes
#
#   # Only run health checks:
#   .\scripts\Main.ps1 -HealthCheckOnly
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [int]$StartFromPhase  = 0,
    [int[]]$ForcePhase    = @(),
    [string]$ForceNode    = '',      # re-run a single node's sentinels
    [switch]$SkipWindowsNodes,       # override: treat WindowsNodeSpecs as @()
    [switch]$HealthCheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot

. "$ScriptDir\Helpers.ps1"
. "$ScriptDir\..\config\variables.ps1"

# Apply runtime overrides
if ($SkipWindowsNodes) {
    $script:WindowsNodeSpecs = @()
    Write-Warn "-SkipWindowsNodes: WindowsNodeSpecs overridden to @()"
}

# ---------------------------------------------------------------------------
function Write-Banner {
    $line = '=' * 72
    Write-Host $line -ForegroundColor Blue
    Write-Host '  Hyper-V k3s Cluster Builder — Multi-Node Edition' -ForegroundColor Blue
    Write-Host $line -ForegroundColor Blue
    Write-Host "  Host:   $env:COMPUTERNAME   ($([System.Environment]::OSVersion.VersionString))" -ForegroundColor Gray
    Write-Host "  CP:     $($script:ControlPlaneVMName)" -ForegroundColor Gray
    $lWorkers  = @(Get-AllLinuxNodeNames | Where-Object { $_ -ne $script:ControlPlaneVMName })
    $wNodes    = @(Get-AllWindowsNodeNames)
    $cni       = $script:CNIPlugin
    Write-Host "  Linux workers: $($lWorkers.Count)  Windows nodes: $($wNodes.Count)  CNI: $cni" -ForegroundColor Gray
    Write-Host "  Repo:   $script:RepoRoot" -ForegroundColor Gray
    Write-Host "  Start:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
    Write-Host $line -ForegroundColor Blue
    Write-Host ''
}

# ---------------------------------------------------------------------------
function Get-OkColor { param([bool]$Ok) if ($Ok) { 'Green' } else { 'Red' } }

function Invoke-HealthCheck {
    Write-PhaseHeader 'HC' 'Health Check — verifying cluster state'

    $kubeconfig = Join-Path $script:OutputDir 'kubeconfig.yaml'

    # Phase 0: binaries
    foreach ($bin in @('packer', 'kubectl', 'ssh')) {
        $ok    = $null -ne (Get-Command $bin -ErrorAction SilentlyContinue)
        $label = if ($ok) { 'OK' } else { 'MISSING' }
        Write-Host "  Phase 0 — $bin on PATH: $label" -ForegroundColor (Get-OkColor $ok)
    }

    $hvOk = $null -ne (Get-Service 'vmms' -ErrorAction SilentlyContinue)
    Write-Host "  Phase 0 — Hyper-V: $(if ($hvOk) { 'Enabled' } else { 'Disabled' })" `
        -ForegroundColor (Get-OkColor $hvOk)

    # Phase 1: vSwitch
    $sw   = Get-VMSwitch -Name $script:vSwitchName -ErrorAction SilentlyContinue
    $swOk = $null -ne $sw -and $sw.SwitchType -eq 'External'
    Write-Host "  Phase 1 — vSwitch '$($script:vSwitchName)': $(if ($sw) { [string]$sw.SwitchType } else { 'NOT FOUND' })" `
        -ForegroundColor (Get-OkColor $swOk)

    # Phase 2: Linux base
    $lBaseOk = Test-PhaseComplete 'linux-base'
    Write-Host "  Phase 2 — Linux base VHDX: $(if ($lBaseOk) { 'OK' } else { 'NOT BUILT' })" `
        -ForegroundColor (Get-OkColor $lBaseOk)

    # Phase 3: Windows bases
    foreach ($v in Get-RequiredWindowsVersions) {
        $wBaseOk = Test-PhaseComplete "win${v}-base"
        Write-Host "  Phase 3 — WS${v} base VHDX: $(if ($wBaseOk) { 'OK' } else { 'NOT BUILT' })" `
            -ForegroundColor (Get-OkColor $wBaseOk)
    }

    # Phases 4-7: individual nodes
    foreach ($name in (Get-AllLinuxNodeNames)) {
        $vm    = Get-VM -Name $name -ErrorAction SilentlyContinue
        $state = if ($vm) { [string]$vm.State } else { 'NOT FOUND' }
        $ok    = $state -eq 'Running'
        Write-Host "  Phase 4 — Linux node '$name': $state" -ForegroundColor (Get-OkColor $ok)
    }
    foreach ($name in (Get-AllWindowsNodeNames)) {
        $vm    = Get-VM -Name $name -ErrorAction SilentlyContinue
        $state = if ($vm) { [string]$vm.State } else { 'NOT FOUND' }
        $ok    = $state -eq 'Running'
        Write-Host "  Phase 5 — Windows node '$name': $state" -ForegroundColor (Get-OkColor $ok)
    }

    $cpOk = Test-PhaseComplete 'cp-bootstrap'
    Write-Host "  Phase 6 — CP bootstrap: $(if ($cpOk) { 'OK' } else { 'NOT DONE' })" `
        -ForegroundColor (Get-OkColor $cpOk)

    $verifyOk = Test-PhaseComplete 'verify'
    Write-Host "  Phase 10 — Verification: $(if ($verifyOk) { 'PASSED' } else { 'NOT RUN' })" `
        -ForegroundColor (Get-OkColor $verifyOk)

    # Cluster connectivity
    $kcExists = Test-Path $kubeconfig
    Write-Host "  Phase 9 — kubeconfig: $(if ($kcExists) { 'OK' } else { 'NOT FOUND' })" `
        -ForegroundColor (Get-OkColor $kcExists)

    if ($kcExists) {
        $env:KUBECONFIG = $kubeconfig
        $null = kubectl cluster-info --request-timeout=8s 2>$null
        $reachable = $LASTEXITCODE -eq 0
        Write-Host "  Cluster reachable: $reachable" -ForegroundColor (Get-OkColor $reachable)
        if ($reachable) {
            Write-Host ''
            Write-Host '  kubectl get nodes:' -ForegroundColor Cyan
            kubectl get nodes -o wide 2>$null | ForEach-Object { Write-Host "    $_" }
        } else {
            Write-Host '  NOTE: VMs may be rebooting. Retry in ~2 min.' -ForegroundColor Yellow
        }
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
function Invoke-Phase {
    param([int]$PhaseNum, [bool]$Forced)

    if ($PhaseNum -lt $StartFromPhase) {
        Write-Host "  [SKIP] Phase $PhaseNum (before -StartFromPhase $StartFromPhase)" -ForegroundColor Gray
        return
    }

    $forceSwitch = if ($Forced) { '-Force' } else { '' }

    switch ($PhaseNum) {
        0 { & "$ScriptDir\Install-Prerequisites.ps1" -Force:$Forced }
        1 { & "$ScriptDir\New-HyperVSwitch.ps1"      -Force:$Forced }
        2 { & "$ScriptDir\Build-LinuxBase.ps1"        -Force:$Forced }
        3 { & "$ScriptDir\Build-WindowsBase.ps1"      -Force:$Forced }
        4 { & "$ScriptDir\New-LinuxNodes.ps1"         -Force:$Forced }
        5 { & "$ScriptDir\New-WindowsNodes.ps1"       -Force:$Forced }
        6 { & "$ScriptDir\Bootstrap-ControlPlane.ps1" -Force:$Forced }
        7 {
            # For Cilium: apply CNI (Phase 8) before joining workers (Phase 7)
            # because nodes stay NotReady until Cilium provides networking.
            if ($script:CNIPlugin -in @('cilium', 'calico', 'antrea') -and $PhaseNum -eq 7) {
                & "$ScriptDir\Apply-CNI.ps1" -Force:$Forced
                if ($LASTEXITCODE -ne 0) { throw "Apply-CNI ($($script:CNIPlugin) pre-join) failed" }
            }
            if ($ForceNode) {
                & "$ScriptDir\Join-Nodes.ps1" -Force:$Forced -ForceNode $ForceNode
            } else {
                & "$ScriptDir\Join-Nodes.ps1" -Force:$Forced
            }
        }
        8 {
            # For Cilium/Calico/Antrea, CNI was already applied in Phase 7 — skip duplicate run.
            if ($script:CNIPlugin -in @('cilium', 'calico', 'antrea')) {
                Write-Host "  [SKIP] Phase 8 ($($script:CNIPlugin) CNI already applied in Phase 7 pre-join step — no duplicate apply needed)" -ForegroundColor Gray
            } else {
                & "$ScriptDir\Apply-CNI.ps1" -Force:$Forced
            }
        }
        9 { & "$ScriptDir\Export-KubeConfig.ps1"  -Force:$Forced }
       10 { & "$ScriptDir\Verify-Cluster.ps1"     -Force:$Forced }
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

Assert-DiskSpace -Path $script:RepoRoot -MinimumGB 50
Initialize-OutputDir $script:OutputDir

$phasesToRun = 0..10
foreach ($phaseNum in $phasesToRun) {
    $forced = $ForcePhase -contains $phaseNum
    try {
        Invoke-Phase -PhaseNum $phaseNum -Forced $forced
    } catch {
        Write-Host ''
        Write-Host ('=' * 72) -ForegroundColor Red
        Write-Host "  FATAL ERROR in Phase $phaseNum" -ForegroundColor Red
        Write-Host "  $_" -ForegroundColor Red
        Write-Host ''
        Write-Host '  To resume from this phase after fixing the issue:' -ForegroundColor Yellow
        Write-Host "    .\scripts\Main.ps1 -StartFromPhase $phaseNum" -ForegroundColor White
        Write-Host ''
        Write-Host '  Packer logs:' -ForegroundColor Yellow
        Write-Host "    $script:OutputDir\packer-linux-base.log" -ForegroundColor Gray
        Write-Host "    $script:OutputDir\packer-win2022-base.log" -ForegroundColor Gray
        Write-Host "    $script:OutputDir\packer-win2025-base.log" -ForegroundColor Gray
        Write-Host ('=' * 72) -ForegroundColor Red
        exit 1
    }
}

Invoke-HealthCheck

$elapsed = (Get-Date) - $startTime
Write-Host ('=' * 72) -ForegroundColor Green
Write-Host "  ALL PHASES COMPLETE" -ForegroundColor Green
Write-Host "  Total time: $([math]::Round($elapsed.TotalMinutes, 1)) minutes" -ForegroundColor Green
Write-Host ''
Write-Host "  `$env:KUBECONFIG = `"$(Join-Path $script:OutputDir 'kubeconfig.yaml')`"" -ForegroundColor White
Write-Host '  kubectl get nodes -o wide' -ForegroundColor White
Write-Host ''
Write-Host "  Full connection details: $(Join-Path $script:OutputDir 'cluster-info.txt')" -ForegroundColor Gray
Write-Host ('=' * 72) -ForegroundColor Green
