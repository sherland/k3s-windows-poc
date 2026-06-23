# =============================================================================
# packer/windows/scripts/05-firstboot-setup.ps1
# Bake the per-node first-boot self-configuration mechanism into the base image.
#
# Creates:
#   C:\k8s-firstboot.ps1     — script that reads C:\k8s-node-config.json
#                              and configures this node (kubeconfigs, kubelet
#                              service registration, hostname, reboot).
#   C:\k8s-firstboot.pending — existence signals that first-boot hasn't run yet
#   ScheduledTask: k8s-firstboot — SYSTEM, AtStartup, runs once
#
# C:\k8s-node-config.json is injected offline (via Mount-VHD / Dismount-VHD)
# by Join-Nodes.ps1 BEFORE the VM is started for the first time.
#
# JSON schema:
# {
#   "hostname":             "k8s-win-01",
#   "k3sServerIP":          "192.168.1.10",
#   "nodeToken":            "<k3s node-token>",
#   "osVersion":            "2025",
#   "kubeconfigB64":        "<base64 kubeconfig>",
#   "flannelKubeconfigB64": "<base64 flannel kubeconfig>"
# }
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Msg) Write-Host "[$(Get-Date -f HH:mm:ss)] $Msg" }

Write-Log "05-firstboot-setup: Creating C:\k8s-firstboot.ps1 ..."

# ---------------------------------------------------------------------------
# Write C:\k8s-firstboot.ps1
# ---------------------------------------------------------------------------
@'
# =============================================================================
# C:\k8s-firstboot.ps1
# Runs once at first boot of a Windows worker node differencing-disk clone.
# Reads C:\k8s-node-config.json (injected offline by Join-Nodes.ps1).
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Log = 'C:\k8s-firstboot.log'
function FbLog($m) { "[$(Get-Date -f HH:mm:ss)] $m" | Tee-Object -FilePath $Log -Append }

$PendingMarker = 'C:\k8s-firstboot.pending'
$ConfigFile    = 'C:\k8s-node-config.json'

if (-not (Test-Path $PendingMarker)) {
    FbLog 'k8s-firstboot: pending marker not found — skipping (already ran or not expected)'
    exit 0
}

if (-not (Test-Path $ConfigFile)) {
    FbLog "k8s-firstboot: ERROR - $ConfigFile not found. Was Join-Nodes.ps1 offline injection done?"
    exit 1
}

FbLog 'k8s-firstboot: reading node config...'
$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$Hostname  = $cfg.hostname
$KDir      = 'C:\k'
$KubeconfigPath        = "$KDir\kubeconfig.yaml"
$FlannelKubeconfigPath = "$KDir\flannel-kubeconfig.yaml"
$KubeletPath           = "$KDir\kubelet.exe"
$PkiDir                = "$KDir\pki"

FbLog "k8s-firstboot: hostname=$Hostname  k3sServerIP=$($cfg.k3sServerIP)"

# ---------------------------------------------------------------------------
# Write kubeconfigs
# ---------------------------------------------------------------------------
[System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String($cfg.kubeconfigB64)) |
    Set-Content -Path $KubeconfigPath -Encoding UTF8
FbLog "k8s-firstboot: $KubeconfigPath written"

[System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String($cfg.flannelKubeconfigB64)) |
    Set-Content -Path $FlannelKubeconfigPath -Encoding UTF8
FbLog "k8s-firstboot: $FlannelKubeconfigPath written"

# Restrict kubeconfig permissions to SYSTEM + Administrators
foreach ($f in @($KubeconfigPath, $FlannelKubeconfigPath)) {
    $acl = Get-Acl $f
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM',         'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('Administrators', 'FullControl', 'Allow')))
    Set-Acl -Path $f -AclObject $acl
}

# ---------------------------------------------------------------------------
# Determine local node IP (first non-loopback, non-APIPA IPv4)
# ---------------------------------------------------------------------------
$nodeIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notmatch '^(169\.254|127\.)' -and
        $_.PrefixOrigin -ne 'WellKnown'
    } |
    Sort-Object -Property InterfaceIndex |
    Select-Object -First 1).IPAddress
FbLog "k8s-firstboot: node IP = $nodeIp"

# ---------------------------------------------------------------------------
# Register kubelet Windows service
# kubelet v1.32 cluster-level settings are in kubelet-config.yaml (written
# by 04-install-k8s-binaries.ps1). We add --hostname-override and --node-ip
# here because they are per-node values.
# ---------------------------------------------------------------------------
$kubeletSvc = 'kubelet'
$existing   = Get-Service $kubeletSvc -ErrorAction SilentlyContinue
if ($existing) {
    Stop-Service $kubeletSvc -Force -ErrorAction SilentlyContinue
    $null = sc.exe delete $kubeletSvc; Start-Sleep -Seconds 2
}

# NOTE: --cloud-provider was removed in k8s 1.33 (KEP-2395 cloud-provider extraction).
# NOTE: --pod-infra-container-image was removed in k8s 1.31; use KubeletConfiguration.podInfraContainerImage instead.
# Both flags cause kubelet v1.33+ to exit immediately with 'unknown flag'.
$kubeletBin = "`"$KubeletPath`" " +
    "--v=2 --windows-service " +
    "--hostname-override=$Hostname " +
    "--node-ip=$nodeIp " +
    "--kubeconfig=`"$KubeconfigPath`" " +
    "--config=`"$KDir\kubelet-config.yaml`" " +
    "--root-dir=C:\var\lib\kubelet " +
    "--cert-dir=`"$PkiDir`" " +
    "--register-with-taints=os=windows:NoSchedule " +
    "--node-labels=kubernetes.io/os=windows"

$null = New-Service -Name $kubeletSvc `
    -BinaryPathName $kubeletBin `
    -DisplayName 'Kubernetes kubelet' `
    -StartupType Automatic `
    -Description 'Kubernetes node agent — registers this Windows node with the k3s control plane'
FbLog 'k8s-firstboot: kubelet service registered'

Start-Service $kubeletSvc
FbLog 'k8s-firstboot: kubelet service started'

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

    # Enable Hyper-V PowerShell management tools.
    # antrea-agent on Windows calls Get-VMNetworkAdapter (in the Hyper-V PS module) to
    # look up the vNIC MAC address after OVS creates the Transparent HNS bridge.
    # Without this module the agent fails with "Get-VMNetworkAdapter is not recognized".
    # RSAT-Hyper-V-Tools-Feature is the parent of Microsoft-Hyper-V-Management-PowerShell.
    FbLog 'k8s-firstboot: enabling RSAT-Hyper-V-Tools-Feature + Hyper-V-Management-PowerShell'
    Enable-WindowsOptionalFeature -Online -FeatureName RSAT-Hyper-V-Tools-Feature -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -NoRestart -ErrorAction SilentlyContinue | Out-Null
    FbLog 'k8s-firstboot: Hyper-V PowerShell module enabled'

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
    # containerd reads CNI config from C:\k\cni\config (set in C:\containerd\config\config.toml),
    # NOT from C:\etc\cni\net.d (where Antrea's install-cni init container writes).
    # The Flannel firstboot leaves 10-flannel.conflist (sdnbridge) in C:\k\cni\config which
    # takes precedence — pods get 'hcnCreateNetwork failed' because sdnbridge tries to create
    # the cbr0 HNS network. Fix: remove the Flannel config and register a FixAntreaCniPath
    # AtStartup task that copies the Antrea config on each boot after install-cni runs.
    FbLog 'k8s-firstboot: removing stale Flannel CNI config from containerd conf_dir'
    Remove-Item 'C:\k\cni\config\10-flannel.conflist' -Force -ErrorAction SilentlyContinue
    $null = New-Item -Force -Path 'C:\k\antrea\Fix-CniConfigPath.ps1' -ItemType File
    Set-Content 'C:\k\antrea\Fix-CniConfigPath.ps1' @(
        '# Wait for Antrea install-cni init container to write the CNI config',
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
        '        # Also copy antrea.exe: install-cni puts it in C:\opt\cni\bin\ but',
        '        # containerd looks in C:\k\cni\ (bin_dir in containerd config.toml).',
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

# ---------------------------------------------------------------------------
# Clean up — remove pending marker and unregister this task
# ---------------------------------------------------------------------------
Remove-Item $PendingMarker -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'k8s-firstboot' -Confirm:$false -ErrorAction SilentlyContinue
FbLog 'k8s-firstboot: cleanup done'

# ---------------------------------------------------------------------------
# Rename computer and reboot
# (Rename-Computer triggers a reboot; after reboot StartNetwork + StartKubeProxy run)
# ---------------------------------------------------------------------------
FbLog "k8s-firstboot: renaming computer to $Hostname and rebooting..."
Rename-Computer -NewName $Hostname -Force
Restart-Computer -Force
'@ | Set-Content -Path 'C:\k8s-firstboot.ps1' -Encoding UTF8

Write-Log "05-firstboot-setup: C:\k8s-firstboot.ps1 written"

# ---------------------------------------------------------------------------
# Create the pending marker (will be checked at first boot)
# ---------------------------------------------------------------------------
'pending' | Set-Content -Path 'C:\k8s-firstboot.pending' -Encoding ascii
Write-Log "05-firstboot-setup: C:\k8s-firstboot.pending created"

# ---------------------------------------------------------------------------
# Register k8s-firstboot as a scheduled task (SYSTEM, AtStartup, one-shot)
# ---------------------------------------------------------------------------
Unregister-ScheduledTask -TaskName 'k8s-firstboot' -Confirm:$false -ErrorAction SilentlyContinue

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NonInteractive -ExecutionPolicy Bypass -File C:\k8s-firstboot.ps1'
$trigger   = New-ScheduledTaskTrigger -AtStartup
$settings  = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName 'k8s-firstboot' `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

Write-Log "05-firstboot-setup: k8s-firstboot scheduled task registered (SYSTEM, AtStartup)"
Write-Log "05-firstboot-setup: Done."
Write-Log "05-firstboot-setup: First boot sequence:"
Write-Log "  1. k8s-firstboot.ps1 reads C:\k8s-node-config.json"
Write-Log "  2. Writes kubeconfigs, registers kubelet service, starts kubelet"
Write-Log "  3. Renames computer to hostname from config"
Write-Log '  4. Reboots - after reboot: StartNetwork, StartKubeProxy tasks run'
