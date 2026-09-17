# =============================================================================
# tests/BuildWindowsBase.Tests.ps1
# Unit tests for Test-WindowsIsoValid (scripts/Build-WindowsBase.ps1) — the
# ISO integrity guard added after a corrupted WS2022 eval ISO download caused
# Windows Setup to hang for 1.5h with no error (Hyper-V integration services
# stuck at "no contact") instead of failing fast. See AGENTS.md Pitfalls.
#
# Build-WindowsBase.ps1 has a real entry point at the bottom (runs the actual
# base-image build on dot-source) and #Requires -RunAsAdministrator, so it
# can't be dot-sourced directly in a test. Instead, extract just the
# Test-WindowsIsoValid function definition via the PowerShell AST and load
# only that — the same technique keeps this test independent of Hyper-V/DISM
# for the fast guard-clause paths, while still exercising the real source.
#
# Run: Invoke-Pester -Path tests/BuildWindowsBase.Tests.ps1 -Output Detailed
# =============================================================================

BeforeDiscovery {
    $script:HaveDiskImageSupport = [bool](Get-Command Mount-DiskImage -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $RepoRoot 'scripts\Build-WindowsBase.ps1'

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
    $funcAst = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-WindowsIsoValid' },
        $true
    ) | Select-Object -First 1

    if (-not $funcAst) {
        throw 'Could not find Test-WindowsIsoValid in Build-WindowsBase.ps1 — has it been renamed or removed?'
    }

    . ([scriptblock]::Create($funcAst.Extent.Text))
}

Describe 'Test-WindowsIsoValid' {
    It 'returns $false when the file does not exist' {
        Test-WindowsIsoValid -IsoPath (Join-Path ([System.IO.Path]::GetTempPath()) "nope-$([guid]::NewGuid()).iso") | Should -BeFalse
    }

    It 'returns $false when the file is smaller than 1GB (obviously truncated)' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) "small-$([guid]::NewGuid()).iso"
        try {
            Set-Content -Path $path -Value 'not a real iso'
            Test-WindowsIsoValid -IsoPath $path | Should -BeFalse
        } finally {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns $false for a large-but-garbage file without throwing (Mount-DiskImage failure is caught)' -Skip:(-not $HaveDiskImageSupport) {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) "garbage-$([guid]::NewGuid()).iso"
        try {
            # 1.1GB of zeros — big enough to pass the size guard, not a real ISO
            $fs = [System.IO.File]::Create($path)
            $fs.SetLength(1181116006)
            $fs.Close()
            { Test-WindowsIsoValid -IsoPath $path } | Should -Not -Throw
            Test-WindowsIsoValid -IsoPath $path | Should -BeFalse
        } finally {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        }
    }
}
