# =============================================================================
# Run-ScenarioE.ps1
# Test Case E: 1 control-plane + 2 Linux workers + 1 Windows node (WS2022)
#              CNI: Flannel (k3s embedded, host-gw) + chained Cilium (Linux only)
#
# k3s starts with Flannel enabled (--flannel-backend=host-gw). After all nodes
# join, Cilium is installed in generic-veth chaining mode using
# config/cni/cilium-chained-values.yaml. Hubble UI is enabled.
# Windows workers join normally via Flannel; Cilium is scoped to Linux nodes.
#
# USAGE (elevated shell):
#   .\Run-ScenarioE.ps1
#   .\Run-ScenarioE.ps1 -NoExtraWorker        # use only 1 Linux worker (skip k8s-lnx-02)
#   .\Run-ScenarioE.ps1 -DeleteGoldenImages   # also rebuild Packer base images from scratch
#   .\Run-ScenarioE.ps1 -SkipCleanup          # skip teardown (e.g. re-run after A passed)
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$SkipCleanup,
    [switch]$DeleteGoldenImages,
    [switch]$NoExtraWorker
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
# 1. Patch config/variables.ps1 for Scenario E
# ---------------------------------------------------------------------------
$workerCount = if ($NoExtraWorker) { 1 } else { 2 }
$workerLabel = if ($NoExtraWorker) { '1 Linux worker' } else { '2 Linux workers (lnx-01: 4 GB, lnx-02: 2 GB)' }
Write-Banner "SCENARIO E — Flannel + Chained Cilium + CP + $workerLabel + 1 Windows node (WS2022)"

$configPath = Join-Path $ScriptRoot 'config\variables.ps1'
$cfg = Get-Content $configPath -Raw

# Set CNI = flannel+cilium
$cfg = $cfg -replace `
    "\`$script:CNIPlugin\s*=\s*'[^']*'([^\n]*)", `
    "`$script:CNIPlugin      = 'flannel+cilium'    # 'flannel' (embedded, default) | 'flannel+cilium' | 'cilium' | 'multus' | 'calico'"

# Set LinuxWorkerCount
$cfg = $cfg -replace `
    "\`$script:LinuxWorkerCount\s*=\s*\d+([^\n]*)", `
    "`$script:LinuxWorkerCount     = $workerCount             # 0 = control-plane only"

# Set WindowsNodeSpecs = 1x WS2022
$cfg = $cfg -replace `
    '(?s)\$script:WindowsNodeSpecs\s*=\s*@\([^)]*\)[^\r\n]*', `
    "`$script:WindowsNodeSpecs    = @(`n    @{ Count = 1; OSVersion = '2022'; CPU = 4; RAM = 7168 }`n)"

Set-Content $configPath $cfg.TrimEnd() -Encoding UTF8 -NoNewline
Write-Host "[OK] config/variables.ps1 → CNI=flannel+cilium, LinuxWorkerCount=$workerCount, WindowsNodeSpecs=1×WS2022" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Teardown
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
    Write-Host "SCENARIO E COMPLETE — all phases passed." -ForegroundColor Green
} else {
    Write-Host "SCENARIO E FAILED (exit $exitCode). Check output above." -ForegroundColor Red
    exit $exitCode
}
