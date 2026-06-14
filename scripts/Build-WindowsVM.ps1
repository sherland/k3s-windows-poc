# =============================================================================
# scripts/Build-WindowsVM.ps1
# Phase 3+4 — Download Windows Server ISO and build the k3s agent VM.
# Idempotent: skipped if the VM already exists and the k3s agent is running.
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

$IsoDir     = Join-Path $script:PackerWindowsDir 'iso'
$IsoPath    = Join-Path $IsoDir 'WS2025-eval.iso'

# ---------------------------------------------------------------------------
# Phase 3 — Download Windows Server 2025 Evaluation ISO
# ---------------------------------------------------------------------------
function Test-Phase3Complete {
    if (-not (Test-PhaseComplete 'phase3')) { return $false }
    return (Test-Path $IsoPath) -and (Get-Item $IsoPath).Length -gt 1GB
}

function Invoke-Phase3 {
    Write-PhaseHeader '3' 'Download Windows Server 2025 Evaluation ISO'

    Assert-DiskSpace -Path $script:RepoRoot -MinimumGB 10

    $null = New-Item -ItemType Directory -Force -Path $IsoDir

    if ((Test-Path $IsoPath) -and (Get-Item $IsoPath).Length -gt 1GB) {
        Write-Success "ISO already downloaded: $IsoPath"
        Set-PhaseComplete 'phase3'
        Write-PhaseDone '3'
        return
    }

    # Use configured local path if provided
    if ($script:WindowsISOLocalPath -and (Test-Path $script:WindowsISOLocalPath)) {
        Write-Step "Using configured local ISO: $($script:WindowsISOLocalPath)"
        Copy-Item $script:WindowsISOLocalPath $IsoPath -Force
        Set-PhaseComplete 'phase3'
        Write-PhaseDone '3'
        return
    }

    Write-Step "Downloading Windows Server 2025 Eval ISO from Microsoft..."
    Write-Warn "This is a ~5 GB download. Ensure stable internet connectivity."

    Invoke-Step 'Download ISO via curl' {
        # Microsoft redirects through a form — follow redirects, save to file
        curl.exe -fsSL -L --max-redirs 10 -o $IsoPath $script:WindowsEvalUrl
        if ($LASTEXITCODE -ne 0) {
            Remove-Item $IsoPath -Force -ErrorAction SilentlyContinue
            throw "curl download failed (exit $LASTEXITCODE). " +
                  "Set `$script:WindowsISOLocalPath in config/variables.ps1 to a pre-downloaded ISO."
        }
    }

    $size = (Get-Item $IsoPath).Length
    if ($size -lt 1GB) {
        Remove-Item $IsoPath -Force
        throw "Downloaded file is suspiciously small ($([math]::Round($size/1MB))MB). " +
              "Microsoft Eval Center download likely failed. " +
              "Download the ISO manually from https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025 " +
              "and set `$script:WindowsISOLocalPath in config/variables.ps1."
    }

    Write-Success "ISO downloaded: $IsoPath ($([math]::Round($size/1GB,1)) GB)"
    Set-PhaseComplete 'phase3'
    Write-PhaseDone '3'
}

# ---------------------------------------------------------------------------
# Phase 4 — Build Windows Server VM
# ---------------------------------------------------------------------------
function Get-LinuxVMToken {
    <#
        Read the k3s join token from the Linux VM via SSH.
        Returns the token string.
    #>
    $ipFile = Join-Path $script:OutputDir 'linux-vm-ip.txt'
    if (-not (Test-Path $ipFile)) {
        throw "Linux VM IP file not found: $ipFile — run Build-LinuxVM.ps1 first."
    }
    $linuxIp = (Get-Content $ipFile).Trim()
    $keyPath = Join-Path $script:OutputDir 'linux-build-key'

    Write-Step "Reading k3s token and kubeconfigs from Linux VM ($linuxIp)..."

    # --- node-token (kept for reference / future use) ---
    $rawToken = Invoke-SshCommand -HostIp $linuxIp -User $script:LinuxAdminUser `
                 -KeyPath $keyPath `
                 -Command 'cat /home/k8sadmin/node-token 2>/dev/null || sudo cat /var/lib/rancher/k3s/server/node-token' `
                 -PassThru
    # ssh 2>&1 can return a mix of strings and ErrorRecord objects (e.g. sudo stderr warnings)
    $token = (($rawToken | Where-Object { $_ -is [string] }) -join "`n").Trim()
    if (-not $token -or $token.Length -lt 10) {
        throw "k3s token appears invalid (length $($token.Length)). SSH into the Linux VM and check /var/lib/rancher/k3s/server/node-token"
    }
    Write-Success "k3s token retrieved (length: $($token.Length))"

    # --- Admin kubeconfig (kubelet uses this to register and run on the node) ---
    # k3s writes the admin kubeconfig with server=127.0.0.1; patch to the real IP.
    $rawKubeconfig = Invoke-SshCommand -HostIp $linuxIp -User $script:LinuxAdminUser `
                 -KeyPath $keyPath `
                 -Command 'sudo cat /etc/rancher/k3s/k3s.yaml' `
                 -PassThru
    $kubeconfigStr = (($rawKubeconfig | Where-Object { $_ -is [string] }) -join "`n").Trim()
    if ($kubeconfigStr.Length -lt 100) {
        throw "Admin kubeconfig appears invalid (length $($kubeconfigStr.Length)). Check /etc/rancher/k3s/k3s.yaml on Linux VM."
    }
    $kubeconfigStr = $kubeconfigStr -replace 'https://127\.0\.0\.1:6443', "https://${linuxIp}:6443"
    $kubeconfigB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($kubeconfigStr))
    Write-Success "Admin kubeconfig retrieved and patched (length: $($kubeconfigStr.Length))"

    # --- Flannel ServiceAccount kubeconfig (flanneld uses this; node-read-only) ---
    $rawFlannelKubeconfig = Invoke-SshCommand -HostIp $linuxIp -User $script:LinuxAdminUser `
                 -KeyPath $keyPath `
                 -Command 'sudo cat /var/lib/rancher/k3s/server/flannel-kubeconfig.yaml' `
                 -PassThru
    $flannelKubeconfigStr = (($rawFlannelKubeconfig | Where-Object { $_ -is [string] }) -join "`n").Trim()
    if ($flannelKubeconfigStr.Length -lt 100) {
        throw "Flannel kubeconfig appears invalid (length $($flannelKubeconfigStr.Length)). Did 02-k3s-server.sh complete successfully?"
    }
    $flannelKubeconfigB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($flannelKubeconfigStr))
    Write-Success "Flannel kubeconfig retrieved (length: $($flannelKubeconfigStr.Length))"

    return @{
        Token                = $token
        ServerIp             = $linuxIp
        KubeconfigB64        = $kubeconfigB64
        FlannelKubeconfigB64 = $flannelKubeconfigB64
    }
}

function Prepare-AutoUnattend {
    $xmlPath = Join-Path $script:PackerWindowsDir 'autounattend\autounattend.xml'
    $content = Get-Content $xmlPath -Raw

    if ($content -match '__WIN_ADMIN_PASS__') {
        $content = $content -replace '__WIN_ADMIN_PASS__', $script:WinAdminPass
        Set-Content -Path $xmlPath -Value $content -NoNewline
        Write-Step "autounattend.xml: admin password set"
    }
}

function Test-Phase4Complete {
    if (-not (Test-PhaseComplete 'phase4')) { return $false }

    $vm = Get-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') { return $false }

    # Quick VMBus check
    try {
        $sess = New-PSSession -VMName $script:WindowsVMName `
                    -Credential (New-Object PSCredential('Administrator', (ConvertTo-SecureString $script:WinAdminPass -AsPlainText -Force))) `
                    -ErrorAction Stop
        $svcState = Invoke-Command -Session $sess -ScriptBlock { [string](Get-Service kubelet -ErrorAction SilentlyContinue).Status }
        Remove-PSSession $sess
        return ($svcState -eq 'Running')
    } catch { return $false }
}

function Assert-Phase4Complete {
    Write-Step "Verifying Phase 4 (Windows VM + k3s agent)..."

    $vm = Get-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
    Assert-True ($null -ne $vm) "VM '$($script:WindowsVMName)' does not exist" 'Re-run Build-WindowsVM.ps1 -Force'
    Assert-True ($vm.State -eq 'Running') "VM '$($script:WindowsVMName)' is not Running (state: $($vm.State))"

    # Check nested virt
    $proc = Get-VMProcessor -VMName $script:WindowsVMName
    Assert-True ($proc.ExposeVirtualizationExtensions -eq $true) `
        'Nested virtualisation not enabled on Windows VM' `
        'Run: Set-VMProcessor -VMName $WindowsVMName -ExposeVirtualizationExtensions $true'

    $winIp = Get-VMIPAddress -VMName $script:WindowsVMName -TimeoutSec 60
    Assert-True ($null -ne $winIp) "Could not get IP for '$($script:WindowsVMName)'"
    Write-Step "Windows VM IP: $winIp"

    # Ensure the VM IP is in WSMan TrustedHosts on this host
    $trusted = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
    if ($trusted -ne '*' -and $trusted -notmatch [regex]::Escape($winIp)) {
        $newTrusted = if ($trusted) { "$trusted,$winIp" } else { $winIp }
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newTrusted -Force
        Write-Step "Added $winIp to WSMan TrustedHosts"
    }

    # Use Hyper-V Direct (VMBus) session — bypasses network WinRM entirely and
    # works even when the host AllowUnencrypted policy is locked to false.
    $cred = New-Object PSCredential('Administrator',
        (ConvertTo-SecureString $script:WinAdminPass -AsPlainText -Force))

    # Wait for VM to be reachable via VMBus (guest services must be running)
    Write-Step "Waiting for VMBus session to become available..."
    Wait-Until -TimeoutSec $script:WinRMTimeoutSec -PollSec 15 -Description 'VMBus session' -Condition {
        try {
            $probe = New-PSSession -VMName $script:WindowsVMName -Credential $cred -ErrorAction Stop
            Remove-PSSession $probe
            return $true
        } catch { return $false }
    }
    $sess = New-PSSession -VMName $script:WindowsVMName -Credential $cred

    try {
        # kubelet may take 30-90s to reach Running after first boot — poll instead of asserting immediately
        Write-Step "Waiting for kubelet service to start..."
        Wait-Until -TimeoutSec 180 -PollSec 15 -Description 'kubelet service Running' -Condition {
            $state = Invoke-Command -Session $sess -ScriptBlock {
                [string](Get-Service kubelet -ErrorAction SilentlyContinue).Status
            }
            return ($state -eq 'Running')
        }

        $ctrdState = Invoke-Command -Session $sess -ScriptBlock {
            [string](Get-Service containerd -ErrorAction SilentlyContinue).Status
        }
        Assert-True ($ctrdState -eq 'Running') "containerd service is not Running (state: $ctrdState)"
    }
    finally {
        if ($sess) { Remove-PSSession $sess }
    }

    Write-Success "Phase 4 OK — Windows VM running, kubelet Running, containerd Running"

    $ipFile = Join-Path $script:OutputDir 'windows-vm-ip.txt'
    Set-Content -Path $ipFile -Value $winIp.Trim()
}

function Invoke-Phase4 {
    Write-PhaseHeader '4' 'Build Windows Server VM (k3s agent + containerd)'

    Assert-DiskSpace -Path $script:RepoRoot -MinimumGB 30

    # Idempotency: if the VM is already imported (Running or Off), skip the
    # Packer build and just boot+verify.  This handles the case where Packer
    # succeeded but Assert-Phase4Complete failed (e.g. WinRM TrustedHosts).
    $existingVm = Get-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
    if ($existingVm) {
        if ($existingVm.State -ne 'Running') {
            Write-Step "VM '$($script:WindowsVMName)' exists but is $($existingVm.State) — starting it"
            Start-VM -Name $script:WindowsVMName
        } else {
            Write-Step "VM '$($script:WindowsVMName)' is already running"
        }
        Write-Step "Skipping Packer rebuild — VM already provisioned"
        Assert-Phase4Complete
        Set-PhaseComplete 'phase4'
        Write-PhaseDone '4'
        return
    }

    # Ensure phase 3 (ISO) is done
    if (-not (Test-Phase3Complete)) {
        throw "Phase 3 (ISO download) is not complete. Run Build-WindowsVM.ps1 again."
    }

    $k3sInfo = Get-LinuxVMToken
    Prepare-AutoUnattend

    $vhdxDir = Join-Path $script:VHDXStoreDir 'windows'
    $diskMB  = $script:DiskSizeGB * 1024
    $memMB   = $script:WindowsMemoryGB * 1024

    # Resolve containerd version
    $ctrdVersion = $script:ContainerdVersion
    if ($ctrdVersion -eq 'latest') {
        $ctrdVersion = Get-LatestGitHubRelease -Repo 'containerd/containerd'
        Write-Step "Resolved containerd version: $ctrdVersion"
    }

    # Remove stale output — stop/unregister VM first so the VHDX isn't locked
    if (Test-Path $vhdxDir) {
        Write-Warn "Removing stale Packer output: $vhdxDir"
        $stale = Get-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
        if ($stale) {
            if ($stale.State -ne 'Off') { Stop-VM -Name $script:WindowsVMName -Force -TurnOff }
            Remove-VM -Name $script:WindowsVMName -Force
        }
        Remove-Item -Recurse -Force $vhdxDir
    }

    Invoke-Step 'Initialize Packer plugins (Windows)' {
        Push-Location $script:PackerWindowsDir
        try {
            packer init .
            if ($LASTEXITCODE -ne 0) { throw "packer init failed with exit code $LASTEXITCODE" }
        }
        finally { Pop-Location }
    }

    Invoke-Step 'Run Packer build (Windows Server)' {
        Push-Location $script:PackerWindowsDir
        try {
            $env:PACKER_LOG      = 1
            $env:PACKER_LOG_PATH = Join-Path $script:OutputDir 'packer-windows.log'

            # Extract pure k8s version (strip +k3sN suffix) for dl.k8s.io download URLs
            $k8sVersion = $script:K3sVersion -replace '\+k3s\d+$', ''

            packer build `
                -var "vm_name=$($script:WindowsVMName)" `
                -var "cpu_count=$($script:WindowsCPU)" `
                -var "memory_mb=$memMB" `
                -var "disk_size_mb=$diskMB" `
                -var "switch_name=$($script:vSwitchName)" `
                -var "admin_pass=$($script:WinAdminPass)" `
                -var "iso_path=$IsoPath" `
                -var "output_dir=$vhdxDir" `
                -var "k8s_version=$k8sVersion" `
                -var "k3s_server_ip=$($k3sInfo.ServerIp)" `
                -var "kubeconfig_b64=$($k3sInfo.KubeconfigB64)" `
                -var "flannel_kubeconfig_b64=$($k3sInfo.FlannelKubeconfigB64)" `
                -var "cluster_dns_ip=$($script:ClusterDnsIp)" `
                -var "cluster_cidr=$($script:ClusterCidr)" `
                -var "service_cidr=$($script:ServiceCidr)" `
                -var "flannel_version=$($script:FlannelVersion)" `
                -var "containerd_version=$ctrdVersion" `
                .

            if ($LASTEXITCODE -ne 0) {
                throw "packer build exited with code $LASTEXITCODE. See $($env:PACKER_LOG_PATH)"
            }
        }
        finally { Pop-Location }
    }

    # Import (re-register) the exported VM — Packer unregisters it after export
    Invoke-Step 'Import Windows VM from Packer export' {
        $existing = Get-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Step "VM already registered — skipping import"
        } else {
            $vmcx = Get-ChildItem -Path $vhdxDir -Recurse -Filter '*.vmcx' | Select-Object -First 1
            Assert-True ($null -ne $vmcx) "No .vmcx found under $vhdxDir — Packer export may have failed."
            Write-Step "Importing VM from: $($vmcx.FullName)"
            Import-VM -Path $vmcx.FullName -Register
            Write-Success "VM '$($script:WindowsVMName)' imported"
        }
    }

    # Enable nested virtualisation BEFORE starting the VM for the provisioning pass
    Invoke-Step 'Enable nested virtualisation on Windows VM' {
        $vm = Get-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
        Assert-True ($null -ne $vm) "VM '$($script:WindowsVMName)' not found after Packer build. Check packer log."
        if ($vm.State -ne 'Off') { Stop-VM -Name $script:WindowsVMName -Force -TurnOff }
        Set-VMProcessor -VMName $script:WindowsVMName -ExposeVirtualizationExtensions $true
        Write-Success "Nested virtualisation enabled on '$($script:WindowsVMName)'"
    }

    Invoke-Step 'Start Windows VM' {
        Start-VM -Name $script:WindowsVMName
    }

    Assert-Phase4Complete
    Set-PhaseComplete 'phase4'
    Write-PhaseDone '4'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($Force) {
    Reset-PhaseComplete 'phase3'
    Reset-PhaseComplete 'phase4'

    # Remove the existing Windows VM so Invoke-Phase4 runs a fresh Packer build
    $vmToRemove = Get-VM -Name $script:WindowsVMName -ErrorAction SilentlyContinue
    if ($vmToRemove) {
        Write-Step "Force: removing existing VM '$($script:WindowsVMName)'..."
        if ($vmToRemove.State -ne 'Off') {
            Stop-VM -Name $script:WindowsVMName -TurnOff -Force -ErrorAction SilentlyContinue
        }
        $diskPaths = Get-VMHardDiskDrive -VMName $script:WindowsVMName -ErrorAction SilentlyContinue |
                     Select-Object -ExpandProperty Path
        Remove-VM -Name $script:WindowsVMName -Force
        foreach ($d in $diskPaths) {
            if ($d -and (Test-Path $d)) { Remove-Item $d -Force -ErrorAction SilentlyContinue }
        }
        Write-Success "Force: VM removed — Packer will rebuild from scratch"
    }
}

if (Test-Phase3Complete) {
    Write-Success 'Phase 3 already complete — skipping ISO download'
} else {
    Invoke-Phase3
}

if (Test-Phase4Complete) {
    Write-Success 'Phase 4 already complete — skipping Windows VM build'
} else {
    Invoke-Phase4
}
