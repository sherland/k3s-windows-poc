# =============================================================================
# Test-ScaleLinuxWorkers.ps1
# End-to-end verification of Scale-LinuxWorkers.ps1.
#
# Test sequence (each step is asserted before proceeding):
#   Step 1 — Scale down to 0 workers
#   Step 2 — Scale up   to 4 workers
#   Step 3 — Scale down to 3 workers (force-drain: -DrainTimeoutSec 0)
#   Step 4 — Scale down to 1 worker
#
# After the run (pass or fail), the cluster is restored to the original
# LinuxWorkerCount unless -SkipRestore is supplied.
#
# Each assertion checks six invariants for the expected worker count N:
#   1. kubectl get nodes — exactly N worker nodes, all Ready
#   2. Hyper-V VMs — exactly N k8s-lnx-* VMs Running
#   3. config/variables.ps1 — LinuxWorkerCount equals N
#   4. Phase sentinels — present for 1..N, absent for N+1..max
#   5. VHDXs — vhdx/nodes/k8s-lnx-NN.vhdx present for 1..N, absent for N+1..max
#   6. Seed ISOs — output/seed-isos/k8s-lnx-NN.iso present for 1..N, absent for N+1..max
#
# USAGE (elevated shell):
#   .\Test-ScaleLinuxWorkers.ps1
#   .\Test-ScaleLinuxWorkers.ps1 -SkipRestore   # leave at count=1 after test
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # Do not restore the original worker count after the test.
    [switch]$SkipRestore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\scripts\Helpers.ps1"
. "$PSScriptRoot\config\variables.ps1"

$KubeconfigPath = Join-Path $script:OutputDir 'admin-kubeconfig.yaml'
$VarFile        = Join-Path $PSScriptRoot 'config\variables.ps1'

$script:PassCount = 0
$script:FailCount = 0
$script:Results   = [System.Collections.Generic.List[string]]::new()

# Highest index that any step will create — used to check sentinels above current count
$MaxWorkerIndex = 4

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Record-Result {
    param([bool]$Pass, [string]$Label, [string]$Detail = '')
    $mark = if ($Pass) { 'PASS' } else { 'FAIL' }
    $color = if ($Pass) { 'Green' } else { 'Red' }
    $full = "  [$mark] $Label$(if ($Detail) { " — $Detail" })"
    $script:Results.Add($full)
    if ($Pass) { $script:PassCount++ } else { $script:FailCount++ }
    Write-Host $full -ForegroundColor $color
}

function Get-CurrentWorkerCount {
    # Re-read from disk (not from the in-memory dot-sourced value)
    $raw = Get-Content $VarFile -Raw
    if ($raw -match '\$script:LinuxWorkerCount\s*=\s*(\d+)') {
        return [int]$Matches[1]
    }
    throw "Could not parse LinuxWorkerCount from $VarFile"
}

function Get-KubectlWorkerNodes {
    $env:KUBECONFIG = $KubeconfigPath
    $out = & kubectl get nodes --no-headers 2>&1
    # Exclude control-plane node
    return @($out | Where-Object { $_ -match '\bReady\b' -and $_ -notmatch '\bmaster\b|\bcontrol-plane\b' })
}

function Get-RunningWorkerVMs {
    return @(Get-VM | Where-Object {
        $_.Name -like "$($script:LinuxWorkerPrefix)-*" -and $_.State -eq 'Running'
    })
}

# ---------------------------------------------------------------------------
# Assert-WorkerCount
# Verifies all six invariants for an expected number of Linux workers.
# ---------------------------------------------------------------------------
function Assert-WorkerCount {
    param([int]$Expected, [string]$StepLabel)

    Write-Host ""
    Write-Host "  --- Assertions for: $StepLabel (expected $Expected worker(s)) ---" -ForegroundColor Cyan

    # 1. kubectl — worker node count and all Ready
    try {
        # Wrap in @() to guard against PowerShell unwrapping empty-array returns to $null
        $workerNodes = @(Get-KubectlWorkerNodes)
        Record-Result ($workerNodes.Count -eq $Expected) `
            "[kubectl] Worker node count = $Expected" "got $($workerNodes.Count)"

        if ($Expected -gt 0) {
            $notReady = @($workerNodes | Where-Object { $_ -notmatch '\bReady\b' })
            Record-Result ($notReady.Count -eq 0) "[kubectl] All $Expected worker(s) Ready" `
                "$(if ($notReady.Count) { "not-ready: $($notReady -join ', ')" })"
        }
    } catch {
        Record-Result $false "[kubectl] Could not query nodes" "$_"
    }

    # 2. Hyper-V — Running VM count
    # Wrap in @() to guard against PowerShell unwrapping empty-array returns to $null
    $vms = @(Get-RunningWorkerVMs)
    Record-Result ($vms.Count -eq $Expected) `
        "[Hyper-V] Running worker VM count = $Expected" "got $($vms.Count)"

    # 3. variables.ps1
    $actualCount = Get-CurrentWorkerCount
    Record-Result ($actualCount -eq $Expected) `
        "[variables.ps1] LinuxWorkerCount = $Expected" "got $actualCount"

    # 4–6. Per-node artefacts: sentinels, VHDXs, seed ISOs
    for ($i = 1; $i -le $MaxWorkerIndex; $i++) {
        $nodeName  = '{0}-{1:D2}' -f $script:LinuxWorkerPrefix, $i
        $shouldExist = ($i -le $Expected)

        # 4. Sentinels
        $sentinelCreated = Test-PhaseComplete "node-$nodeName"
        $sentinelReady   = Test-PhaseComplete "node-$nodeName-ready"
        if ($shouldExist) {
            Record-Result $sentinelCreated "[sentinel] node-$nodeName.done present"
            Record-Result $sentinelReady   "[sentinel] node-$nodeName-ready.done present"
        } else {
            Record-Result (-not $sentinelCreated) "[sentinel] node-$nodeName.done absent"
            Record-Result (-not $sentinelReady)   "[sentinel] node-$nodeName-ready.done absent"
        }

        # 5. VHDX
        $vhdxPath   = Get-NodeVhdxPath $nodeName
        $vhdxExists = Test-Path $vhdxPath
        if ($shouldExist) {
            Record-Result $vhdxExists "[vhdx] $nodeName.vhdx present"
        } else {
            Record-Result (-not $vhdxExists) "[vhdx] $nodeName.vhdx absent"
        }

        # 6. Seed ISO
        $isoPath   = Join-Path $script:OutputDir "seed-isos\$nodeName.iso"
        $isoExists = Test-Path $isoPath
        if ($shouldExist) {
            Record-Result $isoExists "[iso] $nodeName.iso present"
        } else {
            Record-Result (-not $isoExists) "[iso] $nodeName.iso absent"
        }
    }
}

# ---------------------------------------------------------------------------
# Scale helper — calls Scale-LinuxWorkers.ps1 and records outcome
# ---------------------------------------------------------------------------
function Invoke-ScaleStep {
    param(
        [int]$TargetCount,
        [int]$DrainTimeoutSec = 300,
        [string]$Label
    )

    $drainFlag = if ($DrainTimeoutSec -eq 0) { ' -DrainTimeoutSec 0' } else { '' }
    Write-PhaseHeader 'TEST' "$Label"
    Write-Step "Running: .\Scale-LinuxWorkers.ps1 -TargetCount $TargetCount$drainFlag"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($DrainTimeoutSec -eq 0) {
            & "$PSScriptRoot\Scale-LinuxWorkers.ps1" -TargetCount $TargetCount -DrainTimeoutSec 0
        } else {
            & "$PSScriptRoot\Scale-LinuxWorkers.ps1" -TargetCount $TargetCount
        }
        $sw.Stop()
        Record-Result ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null) `
            "[scale] Script exited successfully" "($([int]$sw.Elapsed.TotalSeconds)s)"
    } catch {
        $sw.Stop()
        Record-Result $false "[scale] Script threw an exception" "$_"
        throw   # propagate to outer try/finally so restore still runs
    }
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Write-PhaseHeader 'TEST' 'Scale-LinuxWorkers — Pre-flight'

Assert-True (Test-Path $KubeconfigPath) `
    "Kubeconfig not found at '$KubeconfigPath'. Run the cluster setup first."

$cpVm = Get-VM -Name $script:ControlPlaneVMName -ErrorAction SilentlyContinue
Assert-True ($null -ne $cpVm -and $cpVm.State -eq 'Running') `
    "Control-plane VM '$($script:ControlPlaneVMName)' is not running."

$originalCount = Get-CurrentWorkerCount
Write-Step "Original LinuxWorkerCount = $originalCount (will restore after test)"

$testStart = Get-Date

# ---------------------------------------------------------------------------
# Test sequence
# ---------------------------------------------------------------------------
try {

    # --- Step 1: Scale to 0 ---
    Invoke-ScaleStep -TargetCount 0 -Label 'Step 1: Scale down to 0 workers'
    Assert-WorkerCount -Expected 0 -StepLabel 'After scale to 0'

    # --- Step 2: Scale to 4 ---
    Invoke-ScaleStep -TargetCount 4 -Label 'Step 2: Scale up to 4 workers'
    Assert-WorkerCount -Expected 4 -StepLabel 'After scale to 4'

    # --- Step 3: Scale to 3 (force-drain) ---
    Invoke-ScaleStep -TargetCount 3 -DrainTimeoutSec 0 -Label 'Step 3: Scale down to 3 (force-drain)'
    Assert-WorkerCount -Expected 3 -StepLabel 'After scale to 3 (force-drain)'

    # --- Step 4: Scale to 1 ---
    Invoke-ScaleStep -TargetCount 1 -Label 'Step 4: Scale down to 1 worker'
    Assert-WorkerCount -Expected 1 -StepLabel 'After scale to 1'

} finally {

    # ---------------------------------------------------------------------------
    # Restore
    # ---------------------------------------------------------------------------
    if (-not $SkipRestore) {
        $currentCount = Get-CurrentWorkerCount
        if ($currentCount -ne $originalCount) {
            Write-PhaseHeader 'RESTORE' "Restoring cluster to $originalCount worker(s) (was $currentCount)"
            try {
                & "$PSScriptRoot\Scale-LinuxWorkers.ps1" -TargetCount $originalCount
                Write-Success "Restored to $originalCount worker(s)"
            } catch {
                Write-Warn "Restore failed: $_ — cluster is left at $(Get-CurrentWorkerCount) worker(s)"
            }
        } else {
            Write-Success "Cluster already at $originalCount worker(s) — no restore needed"
        }
    } else {
        Write-Warn "-SkipRestore specified — cluster left at $(Get-CurrentWorkerCount) worker(s)"
    }

    # ---------------------------------------------------------------------------
    # Summary
    # ---------------------------------------------------------------------------
    $elapsed = [int]((Get-Date) - $testStart).TotalSeconds
    $total   = $script:PassCount + $script:FailCount

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Magenta
    Write-Host '  TEST SUMMARY — Scale-LinuxWorkers' -ForegroundColor Magenta
    Write-Host ('=' * 72) -ForegroundColor Magenta
    $script:Results | ForEach-Object { Write-Host $_ }
    Write-Host ''

    $summaryColor = if ($script:FailCount -eq 0) { 'Green' } else { 'Red' }
    Write-Host "  Result : $($script:PassCount) PASS / $($script:FailCount) FAIL / $total total" -ForegroundColor $summaryColor
    Write-Host "  Elapsed: ${elapsed}s" -ForegroundColor $summaryColor
    Write-Host ('=' * 72) -ForegroundColor Magenta
    Write-Host ''

    if ($script:FailCount -gt 0) {
        exit 1
    }
}
