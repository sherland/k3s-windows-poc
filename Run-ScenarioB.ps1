# =============================================================================
# Run-ScenarioB.ps1
# Test Case B: 1 control-plane + 1 Linux worker, NO Windows nodes
#              CNI: multus (meta-plugin on top of k3s flannel)
#
# Tears down any existing cluster (preserving downloaded ISOs and Packer cache),
# patches config/variables.ps1 for Scenario B, then runs all phases 0-10.
#
# USAGE (elevated shell):
#   .\Run-ScenarioB.ps1
#   .\Run-ScenarioB.ps1 -DeleteGoldenImages   # also rebuild Packer base images from scratch
#   .\Run-ScenarioB.ps1 -SkipCleanup          # skip teardown (e.g. re-run after A passed)
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$SkipCleanup,       # skip teardown (useful when chaining after Scenario A)
    [switch]$DeleteGoldenImages # also delete golden base VHDXs so Packer rebuilds them from scratch
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
# 1. Patch config/variables.ps1 for Scenario B
# ---------------------------------------------------------------------------
Write-Banner "SCENARIO B — multus CNI + CP + 1 Linux worker, no Windows nodes"

$configPath = Join-Path $ScriptRoot 'config\variables.ps1'
$cfg = Get-Content $configPath -Raw

# Set CNI = multus
$cfg = $cfg -replace `
    "\`$script:CNIPlugin\s*=\s*'[^']*'([^\n]*)", `
    "`$script:CNIPlugin      = 'multus'    # 'flannel' (embedded, default) | 'cilium' | 'multus'"

# Set WindowsNodeSpecs = empty
$cfg = $cfg -replace `
    '(?s)\$script:WindowsNodeSpecs\s*=\s*@\([^)]*\)[^\r\n]*', `
    "`$script:WindowsNodeSpecs    = @()  # No Windows nodes for Scenario B"

Set-Content $configPath $cfg -Encoding UTF8
Write-Host "[OK] config/variables.ps1 → CNI=multus, WindowsNodeSpecs=@()" -ForegroundColor Green

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
    Write-Host "SCENARIO B COMPLETE — all phases passed." -ForegroundColor Green
} else {
    Write-Host "SCENARIO B FAILED (exit $exitCode). Check output above." -ForegroundColor Red
    exit $exitCode
}
