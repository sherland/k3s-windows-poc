# =============================================================================
# Run-ScenarioA.ps1
# Test Case A: 1 control-plane + 1 Linux worker + 1 Windows node (WS2022)
#              CNI: flannel (k3s embedded)
#
# Tears down any existing cluster (preserving downloaded ISOs and Packer cache),
# patches config/variables.ps1 for Scenario A, then runs all phases 0-10.
#
# USAGE (elevated shell):
#   .\Run-ScenarioA.ps1
#   .\Run-ScenarioA.ps1 -DeleteGoldenImages   # also rebuild Packer base images from scratch
#   .\Run-ScenarioA.ps1 -SkipCleanup          # skip teardown, jump straight to Main.ps1
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$SkipCleanup,       # skip teardown (useful when re-running after partial failure)
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
# 1. Patch config/variables.ps1 for Scenario A
# ---------------------------------------------------------------------------
Write-Banner "SCENARIO A — flannel + CP + 1 Linux worker + 1 Windows node (WS2022)"

$configPath = Join-Path $ScriptRoot 'config\variables.ps1'
$cfg = Get-Content $configPath -Raw

# Set CNI = flannel
$cfg = $cfg -replace `
    "\`$script:CNIPlugin\s*=\s*'[^']*'([^\n]*)", `
    "`$script:CNIPlugin      = 'flannel'    # 'flannel' (embedded, default) | 'cilium' | 'multus'"

# Set WindowsNodeSpecs = 1x WS2022
$cfg = $cfg -replace `
    '(?s)\$script:WindowsNodeSpecs\s*=\s*@\([^)]*\)[^\r\n]*', `
    "`$script:WindowsNodeSpecs    = @(`n    @{ Count = 1; OSVersion = '2022'; CPU = 4; RAM = 7168 }`n)"

Set-Content $configPath $cfg -Encoding UTF8
Write-Host "[OK] config/variables.ps1 → CNI=flannel, WindowsNodeSpecs=1×WS2022" -ForegroundColor Green

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
    Write-Host "SCENARIO A COMPLETE — all phases passed." -ForegroundColor Green
} else {
    Write-Host "SCENARIO A FAILED (exit $exitCode). Check output above." -ForegroundColor Red
    exit $exitCode
}
