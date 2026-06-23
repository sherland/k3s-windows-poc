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
            hostname             = $NodeName
            k3sServerIP          = $CpIp
            nodeToken            = $Token
            osVersion            = $OSVersion
            kubeconfigB64        = $KubeconfigB64
            flannelKubeconfigB64 = $FlannelKcB64
            cniPlugin            = $script:CNIPlugin
            antreaVersion        = $script:AntreaVersion
            clusterDNS           = $script:ClusterDnsIp
            clusterCIDR          = $script:ClusterCidr
            serviceCIDR          = $script:ServiceCidr
        }
        $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgPath -Encoding UTF8
        Write-Success "k8s-node-config.json written to ${driveLetter}:\"

        # ---------------------------------------------------------------------------
        # For Antrea: patch k8s-firstboot.ps1 on the VHDX to inject the Antrea setup
        # block. The base image was built before the Antrea support was added to
        # 05-firstboot-setup.ps1, so the baked-in script doesn't know about Antrea.
        # We patch the script in the differencing disk here so we don't need to
        # rebuild the base image for every Antrea scenario run.
        # ---------------------------------------------------------------------------
        if ($script:CNIPlugin -eq 'antrea') {
            $fbPath = "${driveLetter}:\k8s-firstboot.ps1"
            if (Test-Path $fbPath) {
                $fbContent = Get-Content $fbPath -Raw
                # Only inject if the block isn't already there (idempotent)
                if ($fbContent -notmatch 'CNI-specific first-boot setup \(Antrea\)') {
                    $antreaBlock = @'

# ---------------------------------------------------------------------------
# CNI-specific first-boot setup (Antrea)
# ---------------------------------------------------------------------------
if ($cfg.PSObject.Properties['cniPlugin'] -and $cfg.cniPlugin -eq 'antrea') {
    FbLog 'k8s-firstboot: CNI=antrea — configuring Windows node for Antrea/OVS...'

    # Remove Flannel scheduled tasks baked into the base image.
    # Flannel tasks (StartNetwork + StartKubeProxy) would conflict with Antrea/OVS.
    Unregister-ScheduledTask -TaskName 'StartNetwork'   -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'StartKubeProxy' -Confirm:$false -ErrorAction SilentlyContinue
    FbLog 'k8s-firstboot: Flannel StartNetwork + StartKubeProxy tasks removed'

    # Antrea requires Windows Firewall to be disabled on each node.
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    FbLog 'k8s-firstboot: Windows Firewall disabled'

    # Enable test-signed kernel drivers.
    # The Antrea containerized OVS kernel driver (from antrea-windows-with-ovs.yml) is
    # test-signed. TESTSIGNING must be ON before the driver is installed.
    # This takes effect on next boot — which IS the rename/reboot happening below.
    Bcdedit.exe /set TESTSIGNING ON | Out-Null
    FbLog 'k8s-firstboot: TESTSIGNING ON set (active after reboot)'

    # Enable Hyper-V PowerShell management tools.
    # antrea-agent on Windows calls Get-VMNetworkAdapter (in the Hyper-V PS module) to
    # look up the vNIC MAC address after OVS creates the Transparent HNS bridge.
    # Without this module the agent FAILs with "Get-VMNetworkAdapter is not recognized".
    # Microsoft-Hyper-V is already enabled (installed for container networking).
    # RSAT-Hyper-V-Tools-Feature is the parent of Hyper-V-Management-PowerShell.
    FbLog 'k8s-firstboot: enabling RSAT-Hyper-V-Tools-Feature + Hyper-V-Management-PowerShell'
    Enable-WindowsOptionalFeature -Online -FeatureName RSAT-Hyper-V-Tools-Feature -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -NoRestart -ErrorAction SilentlyContinue | Out-Null
    FbLog 'k8s-firstboot: Hyper-V PowerShell module enabled'

    # Create Antrea helper directory and download version-matched scripts.
    $AntreaDir = 'C:\k\antrea'
    $null = New-Item -ItemType Directory -Force -Path $AntreaDir
    $AntreaVersion = if ($cfg.PSObject.Properties['antreaVersion'] -and $cfg.antreaVersion) { $cfg.antreaVersion } else { '2.6.2' }
    $AntreaTag = "v${AntreaVersion}"
    foreach ($HelperScript in @('Prepare-AntreaAgent.ps1', 'Clean-AntreaNetwork.ps1')) {
        $ScriptUrl = "https://raw.githubusercontent.com/antrea-io/antrea/${AntreaTag}/hack/windows/${HelperScript}"
        FbLog "k8s-firstboot: downloading ${HelperScript} from ${ScriptUrl}"
        try {
            Invoke-WebRequest -Uri $ScriptUrl -OutFile "${AntreaDir}\${HelperScript}" -UseBasicParsing -ErrorAction Stop
            FbLog "k8s-firstboot: ${HelperScript} downloaded OK"
        } catch {
            FbLog "k8s-firstboot: WARNING - failed to download ${HelperScript}: ${_}"
        }
    }

    # Register PrepareAntreaAgent as a persistent AtStartup scheduled task.
    # Runs at every boot (not just first boot) to clean stale OVS bridge / HNS networks
    # before the antrea-agent HostProcess Container starts.
    # -RunOVSServices $false because OVS runs containerized inside the HostProcess Container.
    Unregister-ScheduledTask -TaskName 'PrepareAntreaAgent' -Confirm:$false -ErrorAction SilentlyContinue
    $PrepAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument '-NonInteractive -ExecutionPolicy Bypass -File C:\k\antrea\Prepare-AntreaAgent.ps1 -RunOVSServices $false'
    $PrepTrigger   = New-ScheduledTaskTrigger -AtStartup
    $PrepSettings  = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $PrepPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'PrepareAntreaAgent' `
        -Action $PrepAction -Trigger $PrepTrigger `
        -Settings $PrepSettings -Principal $PrepPrincipal -Force | Out-Null
    FbLog 'k8s-firstboot: PrepareAntreaAgent AtStartup task registered'

    # Fix containerd CNI config path.
    # containerd reads CNI config from C:\k\cni\config (set in config.toml).
    # The Flannel firstboot leaves a 10-flannel.conflist (sdnbridge) there which
    # takes precedence over the Antrea config installed by the install-cni init
    # container (which writes to C:\etc\cni\net.d, kubelet's default path).
    # We must: (1) remove the Flannel config, (2) write the Antrea config to
    # C:\k\cni\config without a BOM (containerd rejects BOM-prefixed JSON).
    FbLog 'k8s-firstboot: fixing containerd CNI config path'
    Remove-Item 'C:\k\cni\config\10-flannel.conflist' -Force -ErrorAction SilentlyContinue
    # The Antrea install-cni init container writes to C:\etc\cni\net.d after first
    # boot. At firstboot time the file may not exist yet — we create a placeholder
    # that will be replaced. A startup script copies it after antrea-agent starts.
    # Register a helper to copy the Antrea CNI config on each boot after agent starts.
    # NOTE: Must NOT use a nested here-string here — this code is inside the outer
    # $antreaBlock single-quoted here-string (@'...'@). A nested @'...'@ would
    # terminate the outer here-string when its closing '@ appears at column 0.
    # Use Set-Content with an array of literals instead (''...'' = escaped single quote).
    $null = New-Item -Force -Path 'C:\k\antrea\Fix-CniConfigPath.ps1' -ItemType File
    Set-Content 'C:\k\antrea\Fix-CniConfigPath.ps1' @(
        '# Wait for Antrea install-cni to write the config',
        'for ($i=0; $i -lt 60; $i++) {',
        '    $src = ''C:\etc\cni\net.d\10-antrea.conflist''',
        '    $dst = ''C:\k\cni\config\10-antrea.conflist''',
        '    if ((Test-Path $src) -and -not (Test-Path $dst)) {',
        '        $null = New-Item -ItemType Directory -Force -Path ''C:\k\cni\config''',
        '        $bytes = [System.IO.File]::ReadAllBytes($src)',
        '        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {',
        '            $bytes = $bytes[3..($bytes.Length-1)]',
        '        }',
        '        [System.IO.File]::WriteAllBytes($dst, $bytes)',
        '        # Also copy the antrea.exe binary: install-cni puts it in C:\opt\cni\bin\ but',
        '        # containerd looks in C:\k\cni\ (bin_dir in C:\containerd\config\config.toml).',
        '        Copy-Item ''C:\opt\cni\bin\antrea.exe'' ''C:\k\cni\antrea.exe'' -Force -ErrorAction SilentlyContinue',
        '        Restart-Service containerd -ErrorAction SilentlyContinue',
        '        break',
        '    }',
        '    Start-Sleep 5',
        '}'
    ) -Encoding ASCII
    $CniAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument '-NonInteractive -ExecutionPolicy Bypass -File C:\k\antrea\Fix-CniConfigPath.ps1'
    $CniTrigger   = New-ScheduledTaskTrigger -AtStartup
    $CniSettings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $CniPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Unregister-ScheduledTask -TaskName 'FixAntreaCniPath' -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName 'FixAntreaCniPath' `
        -Action $CniAction -Trigger $CniTrigger `
        -Settings $CniSettings -Principal $CniPrincipal -Force | Out-Null
    FbLog 'k8s-firstboot: FixAntreaCniPath AtStartup task registered'
}

'@
                    # Insert the Antrea block before the "Clean up" section
                    $injectionPoint = "# ---------------------------------------------------------------------------`r`n# Clean up"
                    if ($fbContent -notmatch [regex]::Escape($injectionPoint)) {
                        $injectionPoint = "# ---------------------------------------------------------------------------`n# Clean up"
                    }
                    # IMPORTANT: use [regex]::Replace with a MatchEvaluator scriptblock instead of
                    # -replace, because $antreaBlock contains ${AntreaTag}, ${HelperScript}, ${_} etc.
                    # .NET regex replacement syntax interprets ${name} as a named capture group reference
                    # and $_ as "entire input" — all would be substituted incorrectly (empty string or
                    # the whole file content). The MatchEvaluator returns the string directly, bypassing
                    # .NET replacement syntax entirely.
                    $capturedAntreaBlock = $antreaBlock
                    $capturedInjectionPoint = $injectionPoint
                    $fbContent = [regex]::Replace(
                        $fbContent,
                        [regex]::Escape($injectionPoint),
                        [System.Text.RegularExpressions.MatchEvaluator]{
                            param($m); $capturedAntreaBlock + $capturedInjectionPoint
                        }
                    )
                    [System.IO.File]::WriteAllText($fbPath, $fbContent, [System.Text.Encoding]::UTF8)
                    Write-Success "k8s-firstboot.ps1 patched with Antrea setup block on ${driveLetter}:\"
                } else {
                    Write-Step "  k8s-firstboot.ps1 already has Antrea block — skipping patch"
                }
            } else {
                Write-Step "  WARNING: k8s-firstboot.ps1 not found at $fbPath — Antrea setup block not injected"
            }
        }
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
    # Load kubeconfig B64 and (optionally) flannel kubeconfig B64 from files saved in Phase 6.
    # flannel-kubeconfig.yaml is only present for Flannel-based CNIs (not Antrea/Cilium/Calico).
    Assert-True (Test-Path $AdminKcPath) "Admin kubeconfig not found at $AdminKcPath"
    $kubeconfigStr = Get-Content $AdminKcPath -Raw
    $kcB64         = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($kubeconfigStr))

    $flannelB64 = ''
    if ($script:CNIPlugin -notin @('cilium', 'calico', 'antrea') -and (Test-Path $FlannelKcPath)) {
        $flannelStr = Get-Content $FlannelKcPath -Raw
        $flannelB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($flannelStr))
    }

    foreach ($name in $osMap.Keys | Sort-Object) {
        $spec = $osMap[$name]
        Join-WindowsWorker -NodeName $name -OSVersion $spec.OSVersion `
            -CpIp $cpIp -Token $token -KubeconfigB64 $kcB64 -FlannelKcB64 $flannelB64
    }

    # For Antrea: wait for antrea-agent-windows pods to reach Running after all Windows nodes
    # have joined. OVS kernel driver installation inside the HostProcess Container takes 1–3 min.
    if ($script:CNIPlugin -eq 'antrea') {
        $winCount = $osMap.Count
        Wait-Until -TimeoutSec 600 -PollSec 15 -Description 'antrea-agent-windows pods Running' -Condition {
            $pods = @(kubectl get pods -n kube-system --no-headers 2>$null |
                Where-Object { $_ -match 'antrea-agent-windows' -and $_ -match '\bRunning\b' })
            Write-Step "  antrea-agent-windows pods Running: $($pods.Count)/$winCount"
            return ($pods.Count -ge $winCount)
        }
        Write-Success "antrea-agent-windows pods Running on all $winCount Windows node(s)"
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
