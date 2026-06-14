# =============================================================================
# scripts/Join-Nodes.ps1
# Phase 7 — Join all worker nodes to the cluster.
#
# Linux workers:
#   SSH in and run the k3s agent install script with K3S_URL + K3S_TOKEN.
#   The k3s binary is already present in the base image, so installation is
#   fast (INSTALL_K3S_SKIP_DOWNLOAD=true).
#
# Windows workers:
#   1. Mount the node's differencing VHDX offline.
#   2. Write C:\k8s-node-config.json with kubeconfig, token, and cluster params.
#   3. Dismount the VHDX.
#   4. Start the VM.
#   5. Wait for the scheduled first-boot task to complete (rename + reboot).
#   6. Wait for VMBus session (Hyper-V Direct — no network WinRM needed).
#   7. Wait for kubelet service to reach Running.
#   8. Wait for node to register in kubectl + become Ready.
#
# Sentinel per node: node-{vmname}-ready.done
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    # Re-run just for a single node by name (skips others)
    [string]$ForceNode = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Helpers.ps1"
. "$PSScriptRoot\..\config\variables.ps1"

$KubeconfigPath = Join-Path $script:OutputDir 'admin-kubeconfig.yaml'
$AdminKcPath    = Join-Path $script:OutputDir 'admin-kubeconfig.yaml'
$TokenFile      = Join-Path $script:OutputDir 'node-token.txt'
$FlannelKcPath  = Join-Path $script:OutputDir 'flannel-kubeconfig.yaml'
$LinuxIPFile    = Join-Path $script:OutputDir 'linux-vm-ip.txt'

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
# Linux worker join
# ---------------------------------------------------------------------------
function Join-LinuxWorker {
    param([string]$NodeName)

    $sentinel = "node-${NodeName}-ready"
    if (-not $Force -and $ForceNode -ne $NodeName -and (Test-PhaseComplete $sentinel)) {
        Write-Success "Linux worker '$NodeName' already joined — skipping"
        return
    }

    Write-Step "--- Joining Linux worker: $NodeName ---"

    $vm = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
    Assert-True ($null -ne $vm) "VM '$NodeName' not found. Run New-LinuxNodes.ps1 first."

    if ($vm.State -ne 'Running') {
        Start-VM -Name $NodeName
    }

    $ip    = Get-VMIPAddress -VMName $NodeName -TimeoutSec $script:VMBootTimeoutSec
    $cpIp  = (Get-Content $LinuxIPFile -Raw).Trim()
    $token = (Get-Content $TokenFile -Raw).Trim()

    # Capture script-scope vars as plain locals for use inside Wait-Until scriptblock
    $nodeIp      = $ip
    $keyPath     = $script:SshKeyPath
    $sshUser     = $script:LinuxAdminUser
    $bootTimeout = $script:VMBootTimeoutSec

    # Wait for SSH
    $sshCondition = {
        $r = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
                 -o ConnectTimeout=5 -i $keyPath `
                 "$sshUser@$nodeIp" 'echo ok' 2>&1
        return ($LASTEXITCODE -eq 0 -and ($r | Where-Object { $_ -is [string] }) -contains 'ok')
    }.GetNewClosure()
    Wait-Until -TimeoutSec $bootTimeout -PollSec 10 -Description "SSH on '$NodeName'" -Condition $sshCondition

    # Install k3s agent (binary already present → skip download)
    Write-Step "Installing k3s agent on '$NodeName'..."
    $installCmd = "curl -sfL https://get.k3s.io | " +
        "K3S_URL='https://${cpIp}:6443' " +
        "K3S_TOKEN='${token}' " +
        "INSTALL_K3S_VERSION='$($script:K3sVersion)' " +
        "INSTALL_K3S_SKIP_DOWNLOAD=true " +
        "sh -"
    Invoke-SshCommand -HostIp $ip -User $script:LinuxAdminUser -KeyPath $script:SshKeyPath `
        -Command $installCmd

    # Wait for k3s-agent to become active
    Wait-Until -TimeoutSec $script:K3sReadyTimeoutSec -PollSec 10 `
        -Description "k3s-agent to become active on '$NodeName'" -Condition {
        $r = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
                 -o ConnectTimeout=10 -i $script:SshKeyPath `
                 "$($script:LinuxAdminUser)@$ip" 'systemctl is-active k3s-agent' 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    Write-Success "k3s-agent active on '$NodeName'"

    # Wait for node to appear and become Ready in kubectl
    Wait-Until -TimeoutSec $script:NodeJoinTimeoutSec -PollSec 15 `
        -Description "'$NodeName' to register in cluster" -Condition {
        $out = kubectl get nodes --no-headers 2>$null
        return [bool]($out | Where-Object { $_ -match [regex]::Escape($NodeName) })
    }
    Wait-Until -TimeoutSec $script:NodeReadyTimeoutSec -PollSec 15 `
        -Description "'$NodeName' to become Ready" -Condition {
        $out = kubectl get node $NodeName --no-headers 2>$null
        return [bool]($out | Where-Object { $_ -match '\bReady\b' })
    }

    Write-Success "Linux worker '$NodeName' is Ready"
    Set-PhaseComplete $sentinel
}

# ---------------------------------------------------------------------------
# Windows worker join
# ---------------------------------------------------------------------------
function Get-WindowsOSDriveLetter {
    param([int]$DiskNumber)
    # Find the largest partition (OS partition) and return its drive letter
    $partition = Get-Partition -DiskNumber $DiskNumber |
        Where-Object { $_.Size -gt 5GB } |
        Sort-Object Size -Descending |
        Select-Object -First 1

    if (-not $partition) {
        throw "Could not find OS partition on disk $DiskNumber"
    }

    $letter = $partition.DriveLetter
    if (-not $letter -or $letter -eq "`0") {
        # Assign a temporary drive letter
        $partition | Add-PartitionAccessPath -AssignDriveLetter
        Start-Sleep -Seconds 2
        $partition = Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.Size -gt 5GB } |
            Sort-Object Size -Descending | Select-Object -First 1
        $letter = $partition.DriveLetter
    }
    return $letter
}

function Inject-WindowsNodeConfig {
    param(
        [string]$NodeName,
        [string]$NodeVhdxPath,
        [string]$CpIp,
        [string]$Token,
        [string]$KubeconfigB64,
        [string]$FlannelKcB64,
        [string]$OSVersion
    )

    Write-Step "Injecting node config into '$NodeName' VHDX (offline)..."
    $disk = Mount-VHD -Path $NodeVhdxPath -Passthru
    try {
        $driveLetter = Get-WindowsOSDriveLetter -DiskNumber $disk.Number
        Assert-True ($driveLetter -ne $null) "Could not get drive letter for $NodeVhdxPath"

        $cfgPath = "${driveLetter}:\k8s-node-config.json"
        $cfg = [ordered]@{
            hostname            = $NodeName
            k3sServerIP         = $CpIp
            nodeToken           = $Token
            osVersion           = $OSVersion
            kubeconfigB64       = $KubeconfigB64
            flannelKubeconfigB64 = $FlannelKcB64
            clusterDNS          = $script:ClusterDnsIp
            clusterCIDR         = $script:ClusterCidr
            serviceCIDR         = $script:ServiceCidr
        }
        $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgPath -Encoding UTF8
        Write-Success "k8s-node-config.json written to ${driveLetter}:\"
    } finally {
        Dismount-VHD -Path $NodeVhdxPath
    }
}

function Join-WindowsWorker {
    param(
        [string]$NodeName,
        [string]$OSVersion,
        [string]$CpIp,
        [string]$Token,
        [string]$KubeconfigB64,
        [string]$FlannelKcB64
    )

    $sentinel = "node-${NodeName}-ready"
    if (-not $Force -and $ForceNode -ne $NodeName -and (Test-PhaseComplete $sentinel)) {
        $env:KUBECONFIG = $KubeconfigPath
        $nodeOut = kubectl get node $NodeName --no-headers 2>$null
        if ($LASTEXITCODE -eq 0 -and ($nodeOut | Where-Object { $_ -match '\bReady\b' })) {
            Write-Success "Windows node '$NodeName' already Ready — skipping"
            return
        }
        Reset-PhaseComplete $sentinel
    }

    Write-Step "--- Joining Windows node: $NodeName (WS$OSVersion) ---"

    $vm = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
    Assert-True ($null -ne $vm) "VM '$NodeName' not found. Run New-WindowsNodes.ps1 first."
    Assert-True ($vm.State -eq 'Off') "VM '$NodeName' must be Off before config injection (state: $($vm.State)). Stop it first."

    $nodeVhdx = Get-NodeVhdxPath $NodeName
    Inject-WindowsNodeConfig -NodeName $NodeName -NodeVhdxPath $nodeVhdx `
        -CpIp $CpIp -Token $Token `
        -KubeconfigB64 $KubeconfigB64 -FlannelKcB64 $FlannelKcB64 `
        -OSVersion $OSVersion

    # Start the VM — first-boot scheduled task will pick up the config
    Write-Step "Starting Windows VM '$NodeName'..."
    Start-VM -Name $NodeName

    # The first-boot script renames the computer and reboots.
    # VM may go Off briefly — handle the same way as the old Join-WindowsNode.ps1.
    $cred = New-Object PSCredential('Administrator',
        (ConvertTo-SecureString $script:WinAdminPass -AsPlainText -Force))

    Write-Step "Waiting for first-boot completion (rename + reboot may occur)..."
    Wait-Until -TimeoutSec ($script:WinRMTimeoutSec * 2) -PollSec 15 `
        -Description "VMBus session on '$NodeName'" -Condition {
        $__vm = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
        if ($__vm -and $__vm.State -ne 'Running') {
            Write-Warn "'$NodeName' is $($__vm.State) (post-firstboot reboot?) — starting..."
            Start-VM -Name $NodeName -ErrorAction SilentlyContinue
            return $false
        }
        try {
            $probe = New-PSSession -VMName $NodeName -Credential $cred -ErrorAction Stop
            Remove-PSSession $probe
            return $true
        } catch { return $false }
    }
    Write-Success "VMBus session available on '$NodeName'"

    $sess = New-PSSession -VMName $NodeName -Credential $cred
    try {
        # Wait for kubelet service Running
        Write-Step "Waiting for kubelet service on '$NodeName'..."
        Wait-Until -TimeoutSec $script:NodeReadyTimeoutSec -PollSec 15 `
            -Description "kubelet Running on '$NodeName'" -Condition {
            $__vm = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
            if ($__vm -and $__vm.State -ne 'Running') {
                Start-VM -Name $NodeName -ErrorAction SilentlyContinue
                return $false
            }
            $state = Invoke-Command -Session $sess -ScriptBlock {
                [string](Get-Service kubelet -ErrorAction SilentlyContinue).Status
            }
            return ($state -eq 'Running')
        }
        Write-Success "kubelet Running on '$NodeName'"

        $ctrdState = Invoke-Command -Session $sess -ScriptBlock {
            [string](Get-Service containerd -ErrorAction SilentlyContinue).Status
        }
        Assert-True ($ctrdState -eq 'Running') "containerd not Running on '$NodeName' (state: $ctrdState)"
    } finally {
        if ($sess) { Remove-PSSession $sess }
    }

    # Wait for node to register in kubectl
    Wait-Until -TimeoutSec $script:NodeJoinTimeoutSec -PollSec 15 `
        -Description "'$NodeName' to register in cluster" -Condition {
        $__vm = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
        if ($__vm -and $__vm.State -ne 'Running') {
            Start-VM -Name $NodeName -ErrorAction SilentlyContinue
            return $false
        }
        $env:KUBECONFIG = $KubeconfigPath
        $allNodes = kubectl get nodes --no-headers 2>$null
        if ($allNodes) { Write-Step "  nodes: $($allNodes -join ' | ')" }
        return [bool]($allNodes | Where-Object { $_ -match [regex]::Escape($NodeName) })
    }

    # Wait for node to become Ready
    Wait-Until -TimeoutSec $script:NodeReadyTimeoutSec -PollSec 15 `
        -Description "'$NodeName' to become Ready" -Condition {
        $__vm = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
        if ($__vm -and $__vm.State -ne 'Running') {
            Start-VM -Name $NodeName -ErrorAction SilentlyContinue
            return $false
        }
        $env:KUBECONFIG = $KubeconfigPath
        $nodeOut = kubectl get node $NodeName --no-headers 2>$null
        $allNodes = kubectl get nodes --no-headers 2>$null
        if ($allNodes) { Write-Step "  nodes: $($allNodes -join ' | ')" }
        return [bool]($nodeOut | Where-Object { $_ -match '\bReady\b' })
    }

    # Label windows node
    Invoke-Kubectl @('label', 'node', $NodeName, 'kubernetes.io/os=windows', '--overwrite') | Out-Null

    # Verify pod CIDR assigned (confirms network setup is running)
    Wait-Until -TimeoutSec 120 -PollSec 10 `
        -Description "'$NodeName' to have pod CIDR assigned" -Condition {
        try {
            $cidr = Invoke-Kubectl @('get', 'node', $NodeName, '-o', 'jsonpath={.spec.podCIDR}')
            return ($cidr -match '\d+\.\d+\.\d+\.\d+/\d+')
        } catch { return $false }
    }

    Write-Success "Windows node '$NodeName' is Ready"
    Set-PhaseComplete $sentinel
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
Write-PhaseHeader '7' 'Join worker nodes to the cluster'

# Ensure kubeconfig is available
Assert-True (Test-Path $KubeconfigPath) "kubeconfig not found at $KubeconfigPath. Run Export-KubeConfig.ps1 first."
Assert-True (Test-Path $TokenFile)      "node-token.txt not found. Run Bootstrap-ControlPlane.ps1 first."

$cpIp   = (Get-Content $LinuxIPFile -Raw).Trim()
$token  = (Get-Content $TokenFile -Raw).Trim()

# Pre-verify CP node is Ready
Invoke-Step "Verify CP node is Ready" {
    Wait-Until -TimeoutSec $script:K3sReadyTimeoutSec -PollSec 10 `
        -Description "CP node '$($script:ControlPlaneVMName)' to be Ready" -Condition {
        $__cpVm = Get-VM -Name $script:ControlPlaneVMName -ErrorAction SilentlyContinue
        if ($__cpVm -and $__cpVm.State -ne 'Running') {
            Start-VM -Name $script:ControlPlaneVMName -ErrorAction SilentlyContinue
            return $false
        }
        $env:KUBECONFIG = $KubeconfigPath
        $out = kubectl get node $script:ControlPlaneVMName --no-headers 2>$null
        return [bool]($out | Where-Object { $_ -match '\bReady\b' })
    }
}

# --- Linux workers ---
$allLinux = Get-AllLinuxNodeNames
foreach ($name in $allLinux) {
    if ($name -eq $script:ControlPlaneVMName) { continue }  # skip CP
    Join-LinuxWorker -NodeName $name
}

# --- Windows workers ---
$osMap = Get-WindowsNodeOSMap
if ($osMap.Count -gt 0) {
    # Load kubeconfig B64 and flannel kubeconfig B64 from files saved in Phase 6
    Assert-True (Test-Path $AdminKcPath) "Admin kubeconfig not found at $AdminKcPath"
    Assert-True (Test-Path $FlannelKcPath) "Flannel kubeconfig not found at $FlannelKcPath"

    $kubeconfigStr = Get-Content $AdminKcPath -Raw
    $flannelStr    = Get-Content $FlannelKcPath -Raw
    $kcB64         = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($kubeconfigStr))
    $flannelB64    = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($flannelStr))

    foreach ($name in $osMap.Keys | Sort-Object) {
        $spec = $osMap[$name]
        Join-WindowsWorker -NodeName $name -OSVersion $spec.OSVersion `
            -CpIp $cpIp -Token $token -KubeconfigB64 $kcB64 -FlannelKcB64 $flannelB64
    }
}

# Final summary
Write-Step 'Cluster node summary:'
$env:KUBECONFIG = $KubeconfigPath
kubectl get nodes -o wide 2>$null | Write-Host

Write-Step ''
Write-Step 'To schedule a Linux test pod:'
Write-Step '  kubectl run linux-test --image=alpine -- sleep 3600'
if ($osMap.Count -gt 0) {
    Write-Step 'To schedule a Windows test pod (Server 2025):'
    Write-Step '  kubectl run win-test --image=mcr.microsoft.com/windows/nanoserver:ltsc2025 --overrides="{\"spec\":{\"nodeSelector\":{\"kubernetes.io/os\":\"windows\"}}}" -- cmd /c "echo hello"'
}

Write-PhaseDone '7'
