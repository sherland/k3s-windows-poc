# =============================================================================
# Run-AllScenarios.ps1
# Orchestrator that runs all (or a subset of) scenarios A–F end-to-end.
#
# Each scenario script handles its own teardown at startup (VMs + sentinels +
# output files). Downloaded ISOs and Packer golden base VHDXs are always
# preserved between runs (-KeepBaseImages is the default in every scenario).
#
# USAGE (elevated shell):
#   .\Run-AllScenarios.ps1                         # run A B C D E F
#   .\Run-AllScenarios.ps1 -Scenarios A,C,E        # subset
#   .\Run-AllScenarios.ps1 -NoExtraWorker          # 1 Linux worker per scenario
#   .\Run-AllScenarios.ps1 -CleanupAfterAll        # tear down after last scenario
#   .\Run-AllScenarios.ps1 -Scenarios A -NoExtraWorker -CleanupAfterAll
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # Which scenarios to run, in order. Valid values: A B C D E F
    [ValidateSet('A','B','C','D','E','F')]
    [string[]]$Scenarios = @('A','B','C','D','E','F'),

    # Pass -NoExtraWorker to each scenario (use 1 Linux worker instead of 2)
    [switch]$NoExtraWorker,

    # Delete golden base VHDXs before the FIRST scenario so Packer rebuilds them.
    # Required after a k3s/containerd version bump. Subsequent scenarios reuse
    # the newly-built golden images (no redundant Packer rebuilds).
    [switch]$DeleteGoldenImages,

    # After the final scenario, tear down all VMs (preserves base images + ISOs)
    [switch]$CleanupAfterAll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Banner([string]$msg, [string]$Color = 'Cyan') {
    $bar = '=' * 72
    Write-Host "`n$bar" -ForegroundColor $Color
    Write-Host "  $msg" -ForegroundColor $Color
    Write-Host "$bar`n" -ForegroundColor $Color
}

function Format-Elapsed([TimeSpan]$ts) {
    if ($ts.TotalHours -ge 1) { return '{0:h\:mm\:ss}' -f $ts }
    return '{0:mm\:ss}' -f $ts
}

# ---------------------------------------------------------------------------
# Build run list
# ---------------------------------------------------------------------------
$ScenarioMap = [ordered]@{
    A = 'Run-ScenarioA.ps1'
    B = 'Run-ScenarioB.ps1'
    C = 'Run-ScenarioC.ps1'
    D = 'Run-ScenarioD.ps1'
    E = 'Run-ScenarioE.ps1'
    F = 'Run-ScenarioF.ps1'
}

# Validate all requested scenarios have a script
foreach ($s in $Scenarios) {
    $scriptFile = Join-Path $ScriptRoot $ScenarioMap[$s]
    if (-not (Test-Path $scriptFile)) {
        throw "Scenario $s script not found: $scriptFile"
    }
}

$Results = [System.Collections.Generic.List[pscustomobject]]::new()

Write-Banner ("Run-AllScenarios  [{0}]  NoExtraWorker={1}  DeleteGoldenImages={2}  CleanupAfterAll={3}" -f
    ($Scenarios -join ','), $NoExtraWorker.IsPresent, $DeleteGoldenImages.IsPresent, $CleanupAfterAll.IsPresent)

Write-Host "  Scenarios     : $($Scenarios -join ', ')" -ForegroundColor White
Write-Host "  Preserve      : ISOs, packer_cache, golden base VHDXs" -ForegroundColor White
Write-Host "  Cleanup mode  : each scenario tears down the previous cluster" -ForegroundColor White
if ($DeleteGoldenImages) {
    Write-Host "  Golden images : will be DELETED and rebuilt by Packer on first scenario" -ForegroundColor Yellow
}
if ($CleanupAfterAll) {
    Write-Host "  Post-run      : cluster will be removed after last scenario" -ForegroundColor White
}
Write-Host ""

$TotalStart = [datetime]::Now

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
$lastScenario = $Scenarios[-1]

for ($i = 0; $i -lt $Scenarios.Count; $i++) {
    $label    = $Scenarios[$i]
    $script   = Join-Path $ScriptRoot $ScenarioMap[$label]
    $isLast   = ($label -eq $lastScenario)

    Write-Banner "SCENARIO $label  ($($i+1) of $($Scenarios.Count))" 'Cyan'

    # Build arg list. -DeleteGoldenImages is passed only to the first scenario so
    # Packer rebuilds the base VHDXs once; subsequent scenarios reuse them.
    # -SkipCleanup is never passed (each scenario cleans up the previous cluster).
    $scenarioArgs = @()
    if ($NoExtraWorker) { $scenarioArgs += '-NoExtraWorker' }
    if ($DeleteGoldenImages -and ($i -eq 0)) { $scenarioArgs += '-DeleteGoldenImages' }

    $start = [datetime]::Now
    $exitCode = 0

    try {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $script @scenarioArgs 2>&1 |
            ForEach-Object { Write-Host $_ }
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Host "EXCEPTION running Scenario $label`: $_" -ForegroundColor Red
        $exitCode = 1
    }

    $elapsed = [datetime]::Now - $start
    $passed  = ($exitCode -eq 0)

    $Results.Add([pscustomobject]@{
        Scenario = $label
        Script   = $ScenarioMap[$label]
        Passed   = $passed
        ExitCode = $exitCode
        Elapsed  = Format-Elapsed $elapsed
    })

    if ($passed) {
        Write-Host "`n  Scenario $label PASSED  ($( Format-Elapsed $elapsed ))" -ForegroundColor Green
    } else {
        Write-Host "`n  Scenario $label FAILED  (exit $exitCode, $( Format-Elapsed $elapsed ))" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Optional post-run teardown
# ---------------------------------------------------------------------------
if ($CleanupAfterAll) {
    Write-Banner "POST-RUN TEARDOWN (preserving ISOs + base images)" 'Yellow'
    $removeArgs = @('-VMs', '-OutputFiles', '-Force', '-KeepBaseImages')
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$ScriptRoot\scripts\Remove-Cluster.ps1" @removeArgs 2>&1 |
        ForEach-Object { Write-Host $_ }
    Write-Host "[OK] Post-run teardown complete." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$totalElapsed = [datetime]::Now - $TotalStart
$passCount    = @($Results | Where-Object Passed).Count
$failCount    = @($Results | Where-Object { -not $_.Passed }).Count

Write-Banner ("ALL-SCENARIOS SUMMARY  —  {0}/{1} passed  ({2})" -f
    $passCount, $Results.Count, (Format-Elapsed $totalElapsed)) `
    $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

# Table
$colW = 10
Write-Host ('  {0,-12} {1,-28} {2,-8} {3,-10} {4}' -f 'Scenario','Script','Result','Exit','Elapsed') -ForegroundColor White
Write-Host ('  {0,-12} {1,-28} {2,-8} {3,-10} {4}' -f '--------','------','------','----','-------') -ForegroundColor DarkGray

foreach ($r in $Results) {
    $resultText  = if ($r.Passed) { 'PASS' } else { 'FAIL' }
    $resultColor = if ($r.Passed) { 'Green' } else { 'Red' }
    Write-Host ('  {0,-12} {1,-28} ' -f "Scenario $($r.Scenario)", $r.Script) -NoNewline
    Write-Host ('{0,-8}' -f $resultText) -ForegroundColor $resultColor -NoNewline
    Write-Host (' {0,-10} {1}' -f $r.ExitCode, $r.Elapsed)
}

Write-Host ""

if ($failCount -eq 0) {
    Write-Host "  ALL SCENARIOS PASSED" -ForegroundColor Green
    exit 0
} else {
    $failedNames = ($Results | Where-Object { -not $_.Passed } | ForEach-Object { "Scenario $($_.Scenario)" }) -join ', '
    Write-Host "  FAILED: $failedNames" -ForegroundColor Red
    exit 1
}
