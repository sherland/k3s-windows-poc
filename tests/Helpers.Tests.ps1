# =============================================================================
# tests/Helpers.Tests.ps1
# Unit tests for the pure/file-based logic in scripts/Helpers.ps1 — topology
# name generation, sentinel bookkeeping, path helpers. No VM/network required.
#
# Run: Invoke-Pester -Path tests/Helpers.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $RepoRoot 'scripts\Helpers.ps1')
}

Describe 'Assert-True' {
    It 'does not throw when condition is true' {
        { Assert-True $true 'should not fire' } | Should -Not -Throw
    }

    It 'throws with the message when condition is false' {
        { Assert-True $false 'boom' } | Should -Throw '*boom*'
    }

    It 'includes remediation text when provided' {
        { Assert-True $false 'boom' 'do the thing' } | Should -Throw '*do the thing*'
    }
}

Describe 'Sentinel helpers' {
    BeforeEach {
        $script:RepoRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helpers-test-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force -Path $script:RepoRoot | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $script:RepoRoot -ErrorAction SilentlyContinue
    }

    It 'reports incomplete before Set-PhaseComplete' {
        Test-PhaseComplete 'phaseX' | Should -BeFalse
    }

    It 'reports complete after Set-PhaseComplete' {
        Set-PhaseComplete 'phaseX'
        Test-PhaseComplete 'phaseX' | Should -BeTrue
    }

    It 'reports incomplete after Reset-PhaseComplete' {
        Set-PhaseComplete 'phaseX'
        Reset-PhaseComplete 'phaseX'
        Test-PhaseComplete 'phaseX' | Should -BeFalse
    }

    It 'Reset-PhaseComplete is a no-op when sentinel does not exist' {
        { Reset-PhaseComplete 'never-set' } | Should -Not -Throw
    }
}

Describe 'Get-AllLinuxNodeNames' {
    BeforeEach {
        $script:ControlPlaneVMName = 'k8s-cp-01'
        $script:LinuxWorkerPrefix  = 'k8s-lnx'
    }

    It 'returns just the control plane when LinuxWorkerCount is 0' {
        $script:LinuxWorkerCount = 0
        Get-AllLinuxNodeNames | Should -Be @('k8s-cp-01')
    }

    It 'returns CP followed by numbered workers, zero-padded' {
        $script:LinuxWorkerCount = 2
        Get-AllLinuxNodeNames | Should -Be @('k8s-cp-01', 'k8s-lnx-01', 'k8s-lnx-02')
    }
}

Describe 'Get-AllWindowsNodeNames / Get-WindowsNodeOSMap / Get-RequiredWindowsVersions' {
    BeforeEach {
        $script:WindowsWorkerPrefix = 'k8s-win'
    }

    It 'returns an empty array when WindowsNodeSpecs is empty' {
        $script:WindowsNodeSpecs = @()
        @(Get-AllWindowsNodeNames).Count | Should -Be 0
        @(Get-RequiredWindowsVersions).Count | Should -Be 0
    }

    It 'numbers nodes globally across multiple spec entries' {
        $script:WindowsNodeSpecs = @(
            @{ Count = 1; OSVersion = '2025'; CPU = 4; RAM = 7168 }
            @{ Count = 2; OSVersion = '2022'; CPU = 4; RAM = 7168 }
        )
        Get-AllWindowsNodeNames | Should -Be @('k8s-win-01', 'k8s-win-02', 'k8s-win-03')
    }

    It 'maps each node name to its OS/CPU/RAM' {
        $script:WindowsNodeSpecs = @(
            @{ Count = 1; OSVersion = '2025'; CPU = 4; RAM = 7168 }
        )
        $map = Get-WindowsNodeOSMap
        $map['k8s-win-01'].OSVersion | Should -Be '2025'
        $map['k8s-win-01'].CPU | Should -Be 4
        $map['k8s-win-01'].RAM | Should -Be 7168
    }

    It 'returns distinct, sorted OS versions across specs' {
        $script:WindowsNodeSpecs = @(
            @{ Count = 1; OSVersion = '2025'; CPU = 4; RAM = 7168 }
            @{ Count = 1; OSVersion = '2022'; CPU = 4; RAM = 7168 }
            @{ Count = 1; OSVersion = '2025'; CPU = 4; RAM = 7168 }
        )
        Get-RequiredWindowsVersions | Should -Be @('2022', '2025')
    }
}

Describe 'Get-BaseVhdxPath' {
    BeforeEach {
        $script:VHDXStoreDir = Join-Path ([System.IO.Path]::GetTempPath()) "vhdx-test-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force -Path $script:VHDXStoreDir | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $script:VHDXStoreDir -ErrorAction SilentlyContinue
    }

    It 'throws for an unknown OS' {
        { Get-BaseVhdxPath -OS 'freebsd' } | Should -Throw "*unknown OS*"
    }

    It 'throws when no .vhdx exists under the expected subdirectory' {
        { Get-BaseVhdxPath -OS 'linux' } | Should -Throw '*No .vhdx found*'
    }

    It 'finds a .vhdx nested under the OS subdirectory' {
        $dir = Join-Path $script:VHDXStoreDir 'linux-base\Virtual Hard Disks'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $expected = Join-Path $dir 'k8s-linux-base.vhdx'
        Set-Content -Path $expected -Value 'fake'
        Get-BaseVhdxPath -OS 'linux' | Should -Be $expected
    }
}
