# =============================================================================
# scripts/Join-WindowsNode.ps1
# Phase 6 — Wait for the Windows node to appear and become Ready in the cluster,
# then label it correctly.
# Idempotent: skipped if node is already Ready and correctly labelled.
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Helpers.ps1"
. "$PSScriptRoot\..\config\variables.ps1"

$KubeconfigPath = Join-Path $script:OutputDir 'kubeconfig.yaml'

# ---------------------------------------------------------------------------
function Get-KubeconfigEnv {
    if (-not (Test-Path $KubeconfigPath)) {
        throw "kubeconfig not found at $KubeconfigPath — run Export-KubeConfig.ps1 first."
    }
    return @{ 'KUBECONFIG' = $KubeconfigPath }
}

function Invoke-Kubectl {
    param([string[]]$KArgs)
    $env:KUBECONFIG = $KubeconfigPath
    $result = & kubectl $KArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($KArgs -join ' ') failed (exit $LASTEXITCODE): $result"
    }
    return $result
}

function Get-NodeNames {
    param([string]$OsLabel)
    $json = Invoke-Kubectl @('get', 'nodes', '-l', "kubernetes.io/os=$OsLabel",
                              '-o', 'jsonpath={.items[*].metadata.name}')
    return ($json -split '\s+' | Where-Object { $_ -ne '' })
}

# ---------------------------------------------------------------------------
function Test-Phase6Complete {
    if (-not (Test-PhaseComplete 'phase6')) { return $false }
    if (-not (Test-Path $KubeconfigPath))   { return $false }

    try {
        $env:KUBECONFIG = $KubeconfigPath
        $nodeOut = kubectl get node $script:WindowsNodeName --no-headers 2>$null
        return ($LASTEXITCODE -eq 0 -and [bool]($nodeOut | Where-Object { $_ -match '\bReady\b' }))
    } catch { return $false }
}

function Assert-Phase6Complete {
    Write-Step "Verifying Phase 6 (Windows node in cluster)..."

    $env:KUBECONFIG = $KubeconfigPath
    $linuxOutput = kubectl get node $script:LinuxVMName --no-headers 2>$null
    Assert-True ($LASTEXITCODE -eq 0 -and ($linuxOutput | Where-Object { $_ -match '\bReady\b' })) `
        "Linux node '$($script:LinuxVMName)' is not Ready (kubectl: $linuxOutput)" `
        'Check k3s server on the Linux VM: sudo systemctl status k3s'

    $winOutput = kubectl get node $script:WindowsNodeName --no-headers 2>$null
    Assert-True ($LASTEXITCODE -eq 0 -and ($winOutput | Where-Object { $_ -match '\bReady\b' })) `
        "Windows node '$($script:WindowsNodeName)' is not Ready (kubectl: $winOutput)" `
        'On Windows VM check: Get-Service kubelet,containerd; Get-Content C:\k\kubelet.log -Tail 30'

    Write-Step "Nodes in cluster:"
    Invoke-Kubectl @('get', 'nodes', '-o', 'wide') | Write-Host

    Write-Success "Phase 6 OK — Linux and Windows nodes are Ready"
}

# ---------------------------------------------------------------------------
function Invoke-Phase6 {
    Write-PhaseHeader '6' 'Wait for Windows node to join the cluster'

    # Ensure kubeconfig exists
    if (-not (Test-Path $KubeconfigPath)) {
        throw "kubeconfig not found. Run Export-KubeConfig.ps1 first (Phase 5 must complete before Phase 6)."
    }

    # Verify Linux node is Ready first.
    # Query by node name rather than by kubernetes.io/os label — the label selector
    # can return empty results if k3s hasn't yet applied the label after a restart.
    Invoke-Step 'Verify Linux node is Ready' {
        Wait-Until -TimeoutSec $script:K3sReadyTimeoutSec -PollSec 10 `
            -Description 'Linux node to become Ready' -Condition {
            $__vm = Get-VM -Name $script:LinuxVMName -ErrorAction SilentlyContinue
            if ($__vm -and $__vm.State -ne 'Running') {
                Write-Warn "Linux VM is $($__vm.State) — starting it back up..."
                Start-VM -Name $script:LinuxVMName -ErrorAction SilentlyContinue
                return $false
            }
            $env:KUBECONFIG = $KubeconfigPath
            $output = kubectl get node $script:LinuxVMName --no-headers 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $output) { return $false }
            return [bool]($output | Where-Object { $_ -match '\bReady\b' })
        }
    }

    # Step 1: Wait for the Windows node to REGISTER (appear in kubectl, any status).
    # On first boot after Packer export, Windows may complete deferred setup and
    # auto-reboot once before the kubelet can register — VM is restarted if it goes Off.
    Invoke-Step 'Wait for Windows node to register with k3s' {
        Wait-Until -TimeoutSec $script:NodeJoinTimeoutSec -PollSec 15 `
            -Description 'Windows node to register' -Condition {
            $__vm = Get-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
            if ($__vm -and $__vm.State -ne 'Running') {
                Write-Warn "Windows VM is $($__vm.State) — starting it back up (post-setup reboot?)..."
                Start-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
                return $false
            }
            $env:KUBECONFIG = $KubeconfigPath
            # Query all nodes; show them for visibility; check if the Windows node name appears
            $allNodes = kubectl get nodes --no-headers 2>$null
            if ($allNodes) { Write-Step "  nodes: $($allNodes -join ' | ')" }
            return [bool](@($allNodes | Where-Object { $_ -match [regex]::Escape($script:WindowsNodeName) }).Count -ge 1)
        }
    }

    # Step 2: Wait for the Windows node to become READY.
    # start-network.ps1 inside the VM waits for k3s to assign a pod CIDR (up to 10 min),
    # creates the cbr0 HNS L2Bridge network, and adds inter-node routes.
    # Allow generous time — this is the slowest part of Windows node startup.
    Invoke-Step 'Wait for Windows node to become Ready' {
        Wait-Until -TimeoutSec $script:NodeReadyTimeoutSec -PollSec 15 `
            -Description 'Windows node to become Ready' -Condition {
            $__vm = Get-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
            if ($__vm -and $__vm.State -ne 'Running') {
                Write-Warn "Windows VM is $($__vm.State) — starting it back up..."
                Start-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
                return $false
            }
            $env:KUBECONFIG = $KubeconfigPath
            # Query the specific Windows node by name — same pattern as the Linux node check
            $nodeOut = kubectl get node $script:WindowsNodeName --no-headers 2>$null
            $allNodes = kubectl get nodes --no-headers 2>$null
            if ($allNodes) { Write-Step "  nodes: $($allNodes -join ' | ')" }
            if ($LASTEXITCODE -ne 0 -or -not $nodeOut) { return $false }
            return [bool]($nodeOut | Where-Object { $_ -match '\bReady\b' })
        }
    }

    # Label the Windows node if not already labelled
    Invoke-Step 'Label Windows node with kubernetes.io/os=windows' {
        $winNodes = @()
        $nodeLines = @(Invoke-Kubectl @('get', 'nodes', '--no-headers'))
        foreach ($line in $nodeLines) {
            if ($line -match 'win') {
                $nodeName = ($line -split '\s+')[0]
                if ($nodeName) { $winNodes += $nodeName }
            }
        }
        foreach ($node in $winNodes) {
            Invoke-Kubectl @('label', 'node', $node, 'kubernetes.io/os=windows', '--overwrite') | Out-Null
            Write-Step "Labelled node: $node"
        }
    }

    # Verify pod CIDR was assigned by the control plane (confirms network setup ran)
    Invoke-Step 'Verify Windows node has pod CIDR assigned' {
        Wait-Until -TimeoutSec 120 -PollSec 10 `
            -Description 'Windows node to have pod CIDR assigned' -Condition {
            try {
                $nodeLines = @(Invoke-Kubectl @('get', 'nodes', '--no-headers'))
                $winLine   = @($nodeLines | Where-Object { $_ -match 'win' -and $_ -match '\bReady\b' })
                if ($winLine.Count -lt 1) { return $false }
                $winNodeName = ($winLine[0] -split '\s+')[0]
                $podCidr = Invoke-Kubectl @('get', 'node', $winNodeName, '-o', 'jsonpath={.spec.podCIDR}')
                return ($podCidr -match '\d+\.\d+\.\d+\.\d+/\d+')
            } catch { return $false }
        }
    }

    Write-Step 'Cluster node summary:'
    Invoke-Kubectl @('get', 'nodes', '-o', 'wide') | Write-Host

    Write-Step ''
    Write-Step 'To schedule a Windows test pod:'
    Write-Step '  kubectl run win-test --image=mcr.microsoft.com/windows/nanoserver:ltsc2022 --overrides="{\"spec\":{\"nodeSelector\":{\"kubernetes.io/os\":\"windows\"},\"tolerations\":[{\"key\":\"os\",\"operator\":\"Equal\",\"value\":\"windows\",\"effect\":\"NoSchedule\"}]}}" -- cmd /c "echo hello && timeout 30"'
    Write-Step ''
    Write-Step 'To schedule a Linux test pod:'
    Write-Step '  kubectl run linux-test --image=alpine -- sleep 3600'

    Assert-Phase6Complete
    Set-PhaseComplete 'phase6'
    Write-PhaseDone '6'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($Force) { Reset-PhaseComplete 'phase6' }

if (Test-Phase6Complete) {
    Write-Success 'Phase 6 already complete — skipping'
} else {
    Invoke-Phase6
}
