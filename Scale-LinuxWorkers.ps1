# =============================================================================
# Scale-LinuxWorkers.ps1
# Scale Linux worker nodes up or down in a running k3s cluster.
#
# Scale-up:
#   Updates variables.ps1 to the new count, then delegates to New-LinuxNodes.ps1
#   (creates new VMs) and Join-Nodes.ps1 (joins new nodes). Existing nodes are
#   skipped automatically via sentinel idempotency.
#
# Scale-down (per node, highest index first):
#   1. kubectl cordon        — stop new workloads scheduling on the node
#   2. kubectl drain         — evict existing workloads to other nodes
#   3. kubectl delete node   — remove the node object from the cluster
#   4. SSH: stop k3s-agent   — clean service shutdown (best-effort)
#   5. Stop + remove VM and VHDX from Hyper-V
#   6. Remove seed ISO from output/seed-isos/
#   7. Remove phase sentinels
#   8. Patch variables.ps1   — kept in sync after every node removal so partial
#                              runs leave config accurate
#
# USAGE (elevated shell):
#   .\Scale-LinuxWorkers.ps1 -TargetCount 3                     # scale up to 3 workers
#   .\Scale-LinuxWorkers.ps1 -TargetCount 1                     # scale down to 1 worker
#   .\Scale-LinuxWorkers.ps1 -TargetCount 1 -DrainTimeoutSec 0  # force-drain (skip PDB checks)
#   .\Scale-LinuxWorkers.ps1 -TargetCount 3 -WhatIf             # preview only, no changes
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    # Desired number of Linux worker nodes (0 = control-plane only).
    [Parameter(Mandatory)]
    [ValidateRange(0, 99)]
    [int]$TargetCount,

    # Drain timeout in seconds per node.
    # 0 = use --force --disable-eviction (skip PDB checks, immediate pod deletion).
    [int]$DrainTimeoutSec = 300,

    # How long (seconds) to poll for the node object to disappear after kubectl delete.
    # 0 = fire-and-forget; do not wait for confirmation.
    [int]$NodeDeleteTimeoutSec = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\scripts\Helpers.ps1"
. "$PSScriptRoot\config\variables.ps1"

$KubeconfigPath = Join-Path $script:OutputDir 'admin-kubeconfig.yaml'
$SeedISODir     = Join-Path $script:OutputDir 'seed-isos'

# ---------------------------------------------------------------------------
# Local kubectl wrapper — sets KUBECONFIG and throws on non-zero exit
# ---------------------------------------------------------------------------
function Invoke-Kubectl {
    param([string[]]$KArgs)
    $env:KUBECONFIG = $KubeconfigPath
    $result = & kubectl $KArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($KArgs -join ' ') failed (exit $LASTEXITCODE): $result"
    }
    return $result
}

# ---------------------------------------------------------------------------
# Patch $script:LinuxWorkerCount in config/variables.ps1 on disk.
# Called after every individual node operation so a partial run leaves the
# file consistent with actual cluster state.
# ---------------------------------------------------------------------------
function Set-LinuxWorkerCount {
    param([int]$Count)
    $varPath = Join-Path $PSScriptRoot 'config\variables.ps1'
    $raw     = Get-Content $varPath -Raw
    $updated = $raw -replace '(\$script:LinuxWorkerCount\s*=\s*)\d+', "`${1}$Count"
    Set-Content -Path $varPath -Value $updated -NoNewline
    Write-Success "variables.ps1 updated: LinuxWorkerCount = $Count"
}

# ---------------------------------------------------------------------------
# Guard checks
# ---------------------------------------------------------------------------
Assert-True (Test-Path $KubeconfigPath) `
    "Kubeconfig not found at '$KubeconfigPath'. Run the cluster setup first (Main.ps1 or a Run-ScenarioX.ps1)."

$cpVm = Get-VM -Name $script:ControlPlaneVMName -ErrorAction SilentlyContinue
Assert-True ($null -ne $cpVm -and $cpVm.State -eq 'Running') `
    "Control-plane VM '$($script:ControlPlaneVMName)' is not running. Start it before scaling."

$linuxBaseDir  = Join-Path $script:VHDXStoreDir 'linux-base'
$linuxBaseVhdx = Get-ChildItem -Path $linuxBaseDir -Recurse -Filter '*.vhdx' `
    -ErrorAction SilentlyContinue | Select-Object -First 1
Assert-True ($null -ne $linuxBaseVhdx) `
    "Linux base VHDX not found under '$linuxBaseDir'. Run Build-LinuxBase.ps1 first."

$currentCount = $script:LinuxWorkerCount

# ---------------------------------------------------------------------------
# No-op
# ---------------------------------------------------------------------------
if ($TargetCount -eq $currentCount) {
    Write-Success "Already at target count ($currentCount Linux worker(s)). Nothing to do."
    exit 0
}

Write-PhaseHeader 'SCALE' "Linux workers: $currentCount  →  $TargetCount"

# ===========================================================================
# SCALE UP
# ===========================================================================
if ($TargetCount -gt $currentCount) {
    $addCount  = $TargetCount - $currentCount
    $lastIndex = '{0:D2}' -f $TargetCount
    Write-Step "Adding $addCount worker(s) — up to $script:LinuxWorkerPrefix-$lastIndex"

    if ($PSCmdlet.ShouldProcess('config\variables.ps1', "Set LinuxWorkerCount = $TargetCount")) {
        Set-LinuxWorkerCount -Count $TargetCount
    }

    if (-not $WhatIfPreference) {
        Write-Step "Creating new node VM(s)..."
        & "$PSScriptRoot\scripts\New-LinuxNodes.ps1"

        Write-Step "Joining new node(s) to the cluster..."
        & "$PSScriptRoot\scripts\Join-Nodes.ps1"
    } else {
        Write-Host "What if: Would call New-LinuxNodes.ps1 and Join-Nodes.ps1 to create and join up to $script:LinuxWorkerPrefix-$lastIndex"
    }

    Write-Success "Scale-up complete — Linux workers: $TargetCount"
    exit 0
}

# ===========================================================================
# SCALE DOWN
# ===========================================================================
$removeCount = $currentCount - $TargetCount
Write-Step "Removing $removeCount worker(s) starting from $script:LinuxWorkerPrefix-$('{0:D2}' -f $currentCount)"

for ($i = $currentCount; $i -gt $TargetCount; $i--) {
    $nodeName = '{0}-{1:D2}' -f $script:LinuxWorkerPrefix, $i

    Write-PhaseHeader 'REMOVE' "Node: $nodeName  ($i → $($i - 1))"

    # -------------------------------------------------------------------------
    # 1. Cordon — stop new workloads from scheduling on this node
    # -------------------------------------------------------------------------
    if ($PSCmdlet.ShouldProcess($nodeName, 'kubectl cordon')) {
        Write-Step "Cordoning '$nodeName'..."
        try {
            Invoke-Kubectl @('cordon', $nodeName)
            Write-Success "Cordoned '$nodeName'"
        } catch {
            Write-Warn "Cordon failed — node may not be registered in cluster: $_ — continuing."
        }
    }

    # -------------------------------------------------------------------------
    # 2. Drain — evict workloads to other nodes
    # -------------------------------------------------------------------------
    if ($PSCmdlet.ShouldProcess($nodeName, 'kubectl drain')) {
        $drainArgs = @('drain', $nodeName, '--ignore-daemonsets', '--delete-emptydir-data')
        if ($DrainTimeoutSec -eq 0) {
            $drainArgs += '--force'
            $drainArgs += '--disable-eviction'
            Write-Step "Draining '$nodeName' (force mode — --disable-eviction)..."
        } else {
            $drainArgs += "--timeout=${DrainTimeoutSec}s"
            Write-Step "Draining '$nodeName' (timeout: ${DrainTimeoutSec}s)..."
        }
        try {
            $env:KUBECONFIG = $KubeconfigPath
            & kubectl $drainArgs 2>&1 | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "Drain exited with code $LASTEXITCODE (timeout or PDB violation) — proceeding with removal."
            } else {
                Write-Success "Drain complete for '$nodeName'"
            }
        } catch {
            Write-Warn "Drain error: $_ — proceeding with removal."
        }
    }

    # -------------------------------------------------------------------------
    # 3. Delete node object from the cluster
    # -------------------------------------------------------------------------
    if ($PSCmdlet.ShouldProcess($nodeName, 'kubectl delete node')) {
        Write-Step "Removing node object '$nodeName' from cluster..."
        try {
            Invoke-Kubectl @('delete', 'node', $nodeName, '--ignore-not-found')
            Write-Success "Node object '$nodeName' deleted."
        } catch {
            Write-Warn "kubectl delete node failed: $_ — continuing."
        }

        if ($NodeDeleteTimeoutSec -gt 0) {
            $kcPath = $KubeconfigPath
            $gone = Wait-Until -TimeoutSec $NodeDeleteTimeoutSec -PollSec 5 -NoThrow `
                -Description "'$nodeName' node object to be removed" `
                -Condition {
                    $env:KUBECONFIG = $kcPath
                    $out = & kubectl get node $nodeName --no-headers 2>&1
                    return ($LASTEXITCODE -ne 0 -or -not ($out | Where-Object { $_ -match [regex]::Escape($nodeName) }))
                }.GetNewClosure()
            if (-not $gone) {
                Write-Warn "Node '$nodeName' still visible after ${NodeDeleteTimeoutSec}s — continuing."
            }
        }
    }

    # -------------------------------------------------------------------------
    # 4. SSH: stop k3s-agent (best-effort — VM may already be unreachable)
    # -------------------------------------------------------------------------
    if ($PSCmdlet.ShouldProcess($nodeName, 'SSH: sudo systemctl stop k3s-agent')) {
        Write-Step "Stopping k3s-agent on '$nodeName' via SSH (best-effort)..."
        try {
            $nodeVm = Get-VM -Name $nodeName -ErrorAction SilentlyContinue
            if ($null -ne $nodeVm -and $nodeVm.State -eq 'Running') {
                $nodeIp = Get-VMIPAddress -VMName $nodeName -TimeoutSec 15
                if ($nodeIp) {
                    Invoke-SshCommand -HostIp $nodeIp -User $script:LinuxAdminUser `
                        -KeyPath $script:SshKeyPath -Command 'sudo systemctl stop k3s-agent'
                    Write-Success "k3s-agent stopped on '$nodeName'"
                }
            } else {
                Write-Warn "VM '$nodeName' is not running — skipping SSH stop."
            }
        } catch {
            Write-Warn "Could not stop k3s-agent on '$nodeName' via SSH: $_ — continuing."
        }
    }

    # -------------------------------------------------------------------------
    # 5. Stop VM, remove VM, remove VHDX
    # -------------------------------------------------------------------------
    if ($PSCmdlet.ShouldProcess($nodeName, 'Stop VM + remove VM + delete VHDX')) {
        $vm = Get-VM -Name $nodeName -ErrorAction SilentlyContinue
        if ($null -ne $vm) {
            $diskPaths = @(
                Get-VMHardDiskDrive -VMName $nodeName -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Path
            )
            if ($vm.State -ne 'Off') {
                Write-Step "Stopping VM '$nodeName'..."
                Stop-VM -Name $nodeName -TurnOff -Force -ErrorAction SilentlyContinue
            }
            Write-Step "Removing VM '$nodeName'..."
            Remove-VM -Name $nodeName -Force
            foreach ($disk in $diskPaths) {
                if ($disk -and (Test-Path $disk)) {
                    Write-Step "Removing disk: $disk"
                    Remove-Item $disk -Force
                }
            }
            Write-Success "VM '$nodeName' removed."
        } else {
            Write-Warn "VM '$nodeName' not found in Hyper-V — skipping VM removal."
        }
    }

    # -------------------------------------------------------------------------
    # 6. Remove seed ISO
    # -------------------------------------------------------------------------
    $seedIso = Join-Path $SeedISODir "$nodeName.iso"
    if (Test-Path $seedIso) {
        if ($PSCmdlet.ShouldProcess($seedIso, 'Remove seed ISO')) {
            Remove-Item $seedIso -Force
            Write-Success "Removed seed ISO: $(Split-Path $seedIso -Leaf)"
        }
    }

    # -------------------------------------------------------------------------
    # 7. Remove phase sentinels
    # -------------------------------------------------------------------------
    if ($PSCmdlet.ShouldProcess("sentinels for $nodeName", 'Remove phase sentinels')) {
        Reset-PhaseComplete "node-$nodeName-ready"
        Reset-PhaseComplete "node-$nodeName"
        Write-Success "Sentinels cleared for '$nodeName'"
    }

    # -------------------------------------------------------------------------
    # 8. Patch variables.ps1 — done after every node so partial runs stay consistent
    # -------------------------------------------------------------------------
    $newCount = $i - 1
    if ($PSCmdlet.ShouldProcess('config\variables.ps1', "Set LinuxWorkerCount = $newCount")) {
        Set-LinuxWorkerCount -Count $newCount
    }
}

Write-Success "Scale-down complete — Linux workers: $TargetCount"
