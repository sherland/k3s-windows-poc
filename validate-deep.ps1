# Deep semantic validation of the k8s Hyper-V scripts
# Checks: function call graph, script variable references, path cross-refs

Set-Location "C:\Source\docker-windows-poc"
$issues = [System.Collections.Generic.List[string]]::new()

function Warn([string]$f, [string]$msg) {
    $issues.Add("[$f] $msg")
    Write-Host "  WARN [$f] $msg" -ForegroundColor Yellow
}
function Pass([string]$msg) {
    Write-Host "  OK   $msg" -ForegroundColor Green
}

# -------------------------------------------------------------------
# 1. Helpers.ps1 — verify all exported functions exist
# -------------------------------------------------------------------
Write-Host "`n=== 1. Helpers.ps1 function exports ===" -ForegroundColor Cyan
$helperContent = Get-Content scripts\Helpers.ps1 -Raw
$helperFunctions = [regex]::Matches($helperContent, '^function\s+(\S+)', 'Multiline') |
                   ForEach-Object { $_.Groups[1].Value }
Write-Host "  Functions defined: $($helperFunctions -join ', ')"

# Functions called in orchestrator scripts that should exist in Helpers.ps1 or locally
$expectedHelpers = @(
    'Write-Step','Write-Success','Write-Warn','Write-PhaseHeader','Write-PhaseDone',
    'Invoke-Step','Assert-DiskSpace','Invoke-WithRetry','Wait-Until',
    'Install-WingetPackage','Invoke-SshCommand','Copy-SshFile','Get-VMIPAddress',
    'Assert-True','Test-PhaseComplete','Set-PhaseComplete','Reset-PhaseComplete',
    'Get-LatestGitHubRelease','Initialize-OutputDir'
)
foreach ($fn in $expectedHelpers) {
    if ($helperFunctions -contains $fn) { Pass "Helper function: $fn" }
    else { Warn 'Helpers.ps1' "Missing function: $fn" }
}

# -------------------------------------------------------------------
# 2. Script variable cross-references (script: scope vars from variables.ps1)
# -------------------------------------------------------------------
Write-Host "`n=== 2. variables.ps1 — all script: vars ===" -ForegroundColor Cyan
$varsContent = Get-Content config\variables.ps1 -Raw
$definedVars = [regex]::Matches($varsContent, '\$script:(\w+)\s*=') |
               ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Write-Host "  Defined script vars: $($definedVars -join ', ')"

# Find all $script:Xxx usages in orchestrator scripts
$usedVars = [System.Collections.Generic.HashSet[string]]::new()
Get-ChildItem scripts\*.ps1 | ForEach-Object {
    $c = Get-Content $_.FullName -Raw
    [regex]::Matches($c, '\$script:(\w+)') | ForEach-Object {
        $null = $usedVars.Add($_.Groups[1].Value)
    }
}
foreach ($v in ($usedVars | Sort-Object)) {
    if ($definedVars -contains $v) { Pass "script:$v used and defined" }
    else { Warn 'variables.ps1' "Used but not defined: `$script:$v" }
}

# -------------------------------------------------------------------
# 3. Packer HCL — variable declarations vs usages
# -------------------------------------------------------------------
Write-Host "`n=== 3. Packer HCL variable cross-reference ===" -ForegroundColor Cyan
foreach ($hclFile in @('packer\linux\ubuntu.pkr.hcl','packer\windows\winserver.pkr.hcl')) {
    $hcl = Get-Content $hclFile -Raw
    $declared = [regex]::Matches($hcl, '^variable\s+"(\w+)"', 'Multiline') |
                ForEach-Object { $_.Groups[1].Value }
    $used     = [regex]::Matches($hcl, 'var\.(\w+)') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $name = Split-Path $hclFile -Leaf
    foreach ($u in $used) {
        if ($declared -contains $u) { Pass "${name}: var.$u declared" }
        else { Warn $name "var.$u used but not declared" }
    }
}

# -------------------------------------------------------------------
# 4. Build-LinuxVM.ps1 — -var flags match HCL variable names
# -------------------------------------------------------------------
Write-Host "`n=== 4. Packer -var flag names match HCL declarations ===" -ForegroundColor Cyan
$linuxHcl    = Get-Content packer\linux\ubuntu.pkr.hcl -Raw
$linuxScript = Get-Content scripts\Build-LinuxVM.ps1 -Raw
$hclVarsL    = [regex]::Matches($linuxHcl, '^variable\s+"(\w+)"','Multiline') |
               ForEach-Object { $_.Groups[1].Value }
$usedVarsL   = [regex]::Matches($linuxScript, '"-var"[^"]*"(\w+)=') |  # not ideal — use next pattern
               ForEach-Object { $_.Groups[1].Value }
# Better: find -var "name=value" patterns
$varFlags    = [regex]::Matches($linuxScript, '`-var\s+"(\w+)=') |
               ForEach-Object { $_.Groups[1].Value }
foreach ($v in $varFlags) {
    if ($hclVarsL -contains $v) { Pass "Linux -var `"$v`" matched" }
    else { Warn 'Build-LinuxVM.ps1' "-var `"$v`" has no matching HCL variable" }
}

$winHcl      = Get-Content packer\windows\winserver.pkr.hcl -Raw
$winScript   = Get-Content scripts\Build-WindowsVM.ps1 -Raw
$hclVarsW    = [regex]::Matches($winHcl, '^variable\s+"(\w+)"','Multiline') |
               ForEach-Object { $_.Groups[1].Value }
$varFlagsW   = [regex]::Matches($winScript, '`-var\s+"(\w+)=') |
               ForEach-Object { $_.Groups[1].Value }
foreach ($v in $varFlagsW) {
    if ($hclVarsW -contains $v) { Pass "Windows -var `"$v`" matched" }
    else { Warn 'Build-WindowsVM.ps1' "-var `"$v`" has no matching HCL variable" }
}

# -------------------------------------------------------------------
# 5. Phase sentinel names — all unique and consistently used
# -------------------------------------------------------------------
Write-Host "`n=== 5. Phase sentinel consistency ===" -ForegroundColor Cyan
$allPS1 = Get-ChildItem scripts\*.ps1 | Get-Content -Raw | Out-String
$sentinels = [regex]::Matches($allPS1, "(?:Test|Set|Reset)-PhaseComplete\s+'([^']+)'") |
             ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Write-Host "  Sentinel names used: $($sentinels -join ', ')"
# Each sentinel should appear in at least a Test-* and a Set-* call
foreach ($s in $sentinels) {
    $hasTest  = $allPS1 -match "Test-PhaseComplete '$s'"
    $hasSet   = $allPS1 -match "Set-PhaseComplete '$s'"
    $hasReset = $allPS1 -match "Reset-PhaseComplete '$s'"
    if ($hasTest -and $hasSet) { Pass "Sentinel '$s': Test + Set present" }
    else { Warn 'sentinels' "Sentinel '$s': Test=$hasTest Set=$hasSet Reset=$hasReset" }
}

# -------------------------------------------------------------------
# 6. Output file paths consistency
# -------------------------------------------------------------------
Write-Host "`n=== 6. Output path consistency ===" -ForegroundColor Cyan
$outputRefs = @('linux-vm-ip.txt','windows-vm-ip.txt','kubeconfig.yaml','cluster-info.txt','linux-build-key')
foreach ($ref in $outputRefs) {
    $found = Get-ChildItem scripts\*.ps1 |
             Where-Object { (Get-Content $_ -Raw) -match [regex]::Escape($ref) }
    if ($found) { Pass "'$ref' referenced in: $($found.Name -join ', ')" }
    else { Warn 'output' "'$ref' not referenced anywhere" }
}

# -------------------------------------------------------------------
# 7. Shell scripts — Unix line endings check
# -------------------------------------------------------------------
Write-Host "`n=== 7. Shell script line endings ===" -ForegroundColor Cyan
foreach ($sh in (Get-ChildItem packer\linux\scripts\*.sh)) {
    $bytes = [System.IO.File]::ReadAllBytes($sh.FullName)
    $hasCR = $bytes -contains [byte]13   # \r
    if ($hasCR) { Warn $sh.Name "Contains CRLF line endings — must be LF only for Linux" }
    else { Pass "$($sh.Name): LF line endings OK" }
}

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
if ($issues.Count -eq 0) {
    Write-Host "  All checks passed!" -ForegroundColor Green
} else {
    Write-Host "  $($issues.Count) issue(s) found:" -ForegroundColor Red
    $issues | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
}
