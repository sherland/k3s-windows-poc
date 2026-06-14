Write-Host '=== System Readiness Check ===' -ForegroundColor Cyan
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Running as admin  : $isAdmin" -ForegroundColor $(if ($isAdmin) { 'Green' } else { 'Red' })

$driveC = Get-PSDrive C
$freeGB = [math]::Round($driveC.Free / 1GB, 1)
Write-Host "C: free space     : ${freeGB} GB" -ForegroundColor $(if ($freeGB -gt 50) { 'Green' } else { 'Yellow' })

$hv = (Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -ErrorAction SilentlyContinue).State
Write-Host "Hyper-V state     : $hv" -ForegroundColor $(if ($hv -eq 'Enabled') { 'Green' } else { 'Yellow' })

foreach ($b in @('packer', 'kubectl', 'ssh', 'winget', 'curl')) {
    $cmd = Get-Command $b -ErrorAction SilentlyContinue
    $msg = if ($cmd) { "found: $($cmd.Source)" } else { 'NOT FOUND' }
    Write-Host "${b,-18}: $msg" -ForegroundColor $(if ($cmd) { 'Green' } else { 'Yellow' })
}
