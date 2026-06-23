# =============================================================================
# Run-ScenarioF.ps1
# Test Case F: 1 control-plane + 2 Linux workers + 1 Windows node (WS2022)
#              CNI: Antrea v2.6.2 (VMware / Open vSwitch — unified Linux + Windows)
#
# Antrea replaces Flannel entirely (k3s is launched with --flannel-backend=none).
# Linux nodes are managed by the Antrea Helm chart (antrea-agent DaemonSet).
# The Windows node is managed by antrea-windows-with-ovs.yml (HostProcess Container,
# containerized OVS, VXLAN tunneling). No Flannel dependency — Antrea handles all
# node networking natively on both Linux and Windows.
#
# Pre-requisites:
#   - TESTSIGNING is enabled on the Windows base image (set by firstboot script)
#   - OVS kernel driver is test-signed (shipped inside antrea-windows-with-ovs image)
#
# USAGE (elevated shell):
#   .\Run-ScenarioF.ps1
#   .\Run-ScenarioF.ps1 -NoExtraWorker        # use only 1 Linux worker (skip k8s-lnx-02)
#   .\Run-ScenarioF.ps1 -DeleteGoldenImages   # also rebuild Packer base images from scratch
#   .\Run-ScenarioF.ps1 -SkipCleanup          # skip teardown (e.g. re-run after E passed)
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
# 1. Patch config/variables.ps1 for Scenario F
# ---------------------------------------------------------------------------
$workerCount = if ($NoExtraWorker) { 1 } else { 2 }
$workerLabel = if ($NoExtraWorker) { '1 Linux worker' } else { '2 Linux workers (lnx-01: 4 GB, lnx-02: 2 GB)' }
Write-Banner "SCENARIO F — Antrea OVS + CP + $workerLabel + 1 Windows node (WS2022)"

$configPath = Join-Path $ScriptRoot 'config\variables.ps1'
$cfg = Get-Content $configPath -Raw

# Set CNI = antrea
$cfg = $cfg -replace `
    "\`$script:CNIPlugin\s*=\s*'[^']*'([^\n]*)", `
    "`$script:CNIPlugin      = 'antrea'    # 'flannel' (embedded, default) | 'flannel+cilium' | 'cilium' | 'multus' | 'calico' | 'antrea'"

# Set LinuxWorkerCount
$cfg = $cfg -replace `
    "\`$script:LinuxWorkerCount\s*=\s*\d+([^\n]*)", `
    "`$script:LinuxWorkerCount     = $workerCount             # 0 = control-plane only"

# Set WindowsNodeSpecs = 1x WS2022
$cfg = $cfg -replace `
    '(?s)\$script:WindowsNodeSpecs\s*=\s*@\([^)]*\)[^\r\n]*', `
    "`$script:WindowsNodeSpecs    = @(`n    @{ Count = 1; OSVersion = '2022'; CPU = 4; RAM = 7168 }`n)"

Set-Content $configPath $cfg.TrimEnd() -Encoding UTF8 -NoNewline
Write-Host "[OK] config/variables.ps1 → CNI=antrea, LinuxWorkerCount=$workerCount, WindowsNodeSpecs=1×WS2022" -ForegroundColor Green

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
    Write-Host "SCENARIO F COMPLETE — all phases passed." -ForegroundColor Green
} else {
    Write-Host "SCENARIO F FAILED (exit $exitCode). Check output above." -ForegroundColor Red
    exit $exitCode
}
