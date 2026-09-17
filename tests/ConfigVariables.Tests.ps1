# =============================================================================
# tests/ConfigVariables.Tests.ps1
# Sanity checks on config/variables.ps1 — version string shapes and the hard
# compatibility invariants documented there (e.g. containerd must stay on the
# 1.x line for Windows kubelet CRI v1 compatibility). Catches typos/shape
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
    It 'ContainerdVersion stays on the 1.x line (Windows kubelet needs the CRI v1 gRPC API removed in containerd v2)' {
        ([version]$script:ContainerdVersion).Major | Should -Be 1
    }

    It "K3sVersion's Kubernetes minor is not 1.36+ (kubelet 1.36 requires containerd 2.0+, conflicting with the 1.x pin above)" {
        if ($script:K3sVersion -match '^v(\d+)\.(\d+)\.') {
            $minor = [int]$Matches[2]
            $minor | Should -BeLessThan 36 -Because 'k3s v1.36 kubelet drops the containerd 1.x cgroup-driver fallback'
        } else {
            throw "Could not parse K3sVersion '$script:K3sVersion'"
        }
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
