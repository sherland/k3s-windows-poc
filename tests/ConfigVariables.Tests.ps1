# =============================================================================
# tests/ConfigVariables.Tests.ps1
# Sanity checks on config/variables.ps1 — version string shapes and the hard
# compatibility invariants documented there (e.g. containerd must be >= 2.2
# for the Windows kubelet). Catches typos/shape
# mistakes and silent regressions of documented constraints, not "is this the
# latest version" (that's a human/AI judgement call, not a test).
#
# Run: Invoke-Pester -Path tests/ConfigVariables.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $RepoRoot 'config\variables.ps1')
}

Describe 'Version string shapes' {
    It 'K3sVersion looks like vX.Y.Z+k3sN' {
        $script:K3sVersion | Should -Match '^v\d+\.\d+\.\d+\+k3s\d+$'
    }

    It 'ContainerdVersion looks like X.Y.Z (no leading v)' {
        $script:ContainerdVersion | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'FlannelVersion looks like vX.Y.Z' {
        $script:FlannelVersion | Should -Match '^v\d+\.\d+\.\d+$'
    }

    It 'WinsCniVersion looks like vX.Y.Z' {
        $script:WinsCniVersion | Should -Match '^v\d+\.\d+\.\d+$'
    }

    It 'MultusVersion looks like vX.Y.Z' {
        $script:MultusVersion | Should -Match '^v\d+\.\d+\.\d+$'
    }

    It 'CniPluginsVersion looks like vX.Y.Z' {
        $script:CniPluginsVersion | Should -Match '^v\d+\.\d+\.\d+$'
    }

    It 'CiliumVersion looks like X.Y.Z (no leading v — bare Helm --version arg)' {
        $script:CiliumVersion | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'CalicoVersion looks like vX.Y.Z' {
        $script:CalicoVersion | Should -Match '^v\d+\.\d+\.\d+$'
    }

    It 'AntreaVersion looks like X.Y.Z (no leading v — bare Helm --version arg)' {
        $script:AntreaVersion | Should -Match '^\d+\.\d+\.\d+$'
    }
}

Describe 'Hard compatibility invariants' {
    It 'ContainerdVersion is >= 2.2 (k8s 1.36 requires containerd 2.2+/2.3+ per containerd RELEASES.md)' {
        ([version]$script:ContainerdVersion) | Should -BeGreaterOrEqual ([version]'2.2.0')
    }
}

Describe 'Topology constraints' {
    It 'ControlPlaneVMName is <=15 chars (Windows-compatible k8s node name)' {
        $script:ControlPlaneVMName.Length | Should -BeLessOrEqual 15
    }

    It 'WindowsWorkerPrefix is short enough that numbered names stay <=15 chars' {
        # e.g. 'k8s-win' + '-01' = 10 chars; leave headroom for -NN suffix (3 chars)
        $script:WindowsWorkerPrefix.Length | Should -BeLessOrEqual 12
    }

    It 'CNIPlugin is one of the documented valid values' {
        $script:CNIPlugin | Should -BeIn @('flannel', 'flannel+cilium', 'cilium', 'multus', 'calico', 'antrea', 'none')
    }
}
