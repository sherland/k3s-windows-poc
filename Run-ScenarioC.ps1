# =============================================================================
# Run-ScenarioC.ps1
# Test Case C: 1 control-plane + 2 Linux workers, NO Windows nodes
#              CNI: Cilium (replaces k3s embedded flannel entirely)
#
# k3s is started with --flannel-backend=none so that Cilium owns all networking.
# Cilium is installed via Helm using config/cni/cilium-values.yaml.
#
# Tears down any existing cluster (preserving downloaded ISOs and Packer cache),
# patches config/variables.ps1 for Scenario C, then runs all phases 0-10.
#
# USAGE (elevated shell):
#   .\Run-ScenarioC.ps1
#   .\Run-ScenarioC.ps1 -NoExtraWorker        # use only 1 Linux worker (skip k8s-lnx-02)
#   .\Run-ScenarioC.ps1 -DeleteGoldenImages   # also rebuild Packer base images from scratch
#   .\Run-ScenarioC.ps1 -SkipCleanup          # skip teardown (e.g. re-run after B passed)
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$SkipCleanup,       # skip teardown (useful when chaining after Scenario B)
    [switch]$DeleteGoldenImages,# also delete golden base VHDXs so Packer rebuilds them from scratch
    [switch]$NoExtraWorker      # skip the extra Linux worker (k8s-lnx-02); use only 1 Linux worker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot

function Write-Banner([string]$msg) {
    $bar = '=' * 72
    Write-Host "`n$bar" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "$bar`n" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 1. Patch config/variables.ps1 for Scenario C
# ---------------------------------------------------------------------------
$workerCount = if ($NoExtraWorker) { 1 } else { 2 }
$workerLabel = if ($NoExtraWorker) { '1 Linux worker' } else { '2 Linux workers (lnx-01: 4 GB, lnx-02: 2 GB)' }
Write-Banner "SCENARIO C — Cilium CNI + CP + $workerLabel, no Windows nodes"

$configPath = Join-Path $ScriptRoot 'config\variables.ps1'
$cfg = Get-Content $configPath -Raw

# Set CNI = cilium
$cfg = $cfg -replace `
    "\`$script:CNIPlugin\s*=\s*'[^']*'([^\n]*)", `
    "`$script:CNIPlugin      = 'cilium'    # 'flannel' (embedded, default) | 'cilium' | 'multus'"

# Set LinuxWorkerCount
$cfg = $cfg -replace `
    "\`$script:LinuxWorkerCount\s*=\s*\d+([^\n]*)", `
    "`$script:LinuxWorkerCount     = $workerCount             # 0 = control-plane only"

# Set WindowsNodeSpecs = empty (Cilium is Linux-only)
$cfg = $cfg -replace `
    '(?s)\$script:WindowsNodeSpecs\s*=\s*@\([^)]*\)[^\r\n]*', `
    "`$script:WindowsNodeSpecs    = @()  # No Windows nodes for Scenario C"

Set-Content $configPath $cfg -Encoding UTF8
Write-Host "[OK] config/variables.ps1 → CNI=cilium, LinuxWorkerCount=$workerCount, WindowsNodeSpecs=@()" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Teardown (VMs + VHDXs + sentinels + output files, keep ISOs + cache)
# ---------------------------------------------------------------------------
if (-not $SkipCleanup) {
    Write-Banner "TEARDOWN (preserving packer_cache and ISOs)"
    $removeArgs = @('-VMs', '-OutputFiles', '-Force')
    if (-not $DeleteGoldenImages) { $removeArgs += '-KeepBaseImages' }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$ScriptRoot\scripts\Remove-Cluster.ps1" @removeArgs
    if ($LASTEXITCODE -ne 0) { throw "Remove-Cluster.ps1 failed (exit $LASTEXITCODE)" }
    Write-Host "[OK] Cluster removed." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 3. Run all phases 0-10
# ---------------------------------------------------------------------------
Write-Banner "RUNNING ALL PHASES (0 → 10)"
& pwsh -NoProfile -ExecutionPolicy Bypass -File "$ScriptRoot\scripts\Main.ps1" 2>&1 |
    ForEach-Object { Write-Host $_ }

$exitCode = $LASTEXITCODE
Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "SCENARIO C COMPLETE — all phases passed." -ForegroundColor Green
} else {
    Write-Host "SCENARIO C FAILED (exit $exitCode). Check output above." -ForegroundColor Red
    exit $exitCode
}
