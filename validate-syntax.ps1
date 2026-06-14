Set-Location "C:\Source\docker-windows-poc"
$ok = 0; $fail = 0
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
    $pe = [System.Management.Automation.Language.ParseError[]]@()
    $t  = [System.Management.Automation.Language.Token[]]@()
    $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$pe)
    if ($pe.Length -gt 0) {
        $fail++
        Write-Host "FAIL $($_.Name)"
        foreach ($e in $pe) { Write-Host "     L$($e.Extent.StartLineNumber): $($e.Message)" }
    } else {
        $ok++
        Write-Host "OK   $($_.Name)"
    }
}
Write-Host "--- OK:$ok  FAIL:$fail ---"
