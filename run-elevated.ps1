# =============================================================================
# run-elevated.ps1
# Launches Main.ps1 (or any specified script) in an elevated PowerShell process
# and tees all output to output\run.log so it can be monitored from a
# non-elevated terminal.
# Usage:
#   .\run-elevated.ps1                          # runs Main.ps1
#   .\run-elevated.ps1 -Script scripts\Install-Prerequisites.ps1
#   .\run-elevated.ps1 -Args '-StartFromPhase 4'
# =============================================================================
param(
    [string]$Script = 'scripts\Main.ps1',
    [string]$Args   = ''
)

$repoRoot = Split-Path $MyInvocation.MyCommand.Path
$logDir   = Join-Path $repoRoot 'output'
$logFile  = Join-Path $logDir 'run.log'

# Ensure output dir exists (may not exist yet on first run)
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

# Clear previous log
'' | Set-Content $logFile

$scriptPath = Join-Path $repoRoot $Script
$innerCmd   = "& { & '$scriptPath' $Args *>&1 | Tee-Object -FilePath '$logFile'; exit `$LASTEXITCODE }"

Write-Host "Launching elevated process..." -ForegroundColor Cyan
Write-Host "Log file: $logFile" -ForegroundColor Cyan
Write-Host "Tail with:  Get-Content '$logFile' -Wait" -ForegroundColor Yellow
Write-Host ""

$proc = Start-Process pwsh `
    -Verb RunAs `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command $innerCmd" `
    -PassThru

Write-Host "Elevated PID: $($proc.Id)  — waiting for completion..." -ForegroundColor Cyan
$proc.WaitForExit()
$exitCode = $proc.ExitCode
Write-Host ""
Write-Host "Elevated process exited with code: $exitCode" -ForegroundColor $(if ($exitCode -eq 0) { 'Green' } else { 'Red' })
Write-Host "Full log: $logFile" -ForegroundColor Cyan
