# =============================================================================
# scripts/Build-LinuxVM.ps1
# Phase 2 — Build the Ubuntu 24.04 k3s server VM with Packer.
# Idempotent: skipped if the VM already exists and k3s is active.
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

# (SshKeyPath is defined in config/variables.ps1 as $script:SshKeyPath)

# ---------------------------------------------------------------------------
function Get-UbuntuISO {
    <#
        Resolves the ISO URL and SHA256 checksum from the Ubuntu releases page.
        Uses variables.ps1 overrides when set.
    #>
    if ($script:UbuntuISOUrl -and $script:UbuntuISOChecksum) {
        Write-Step "Using configured Ubuntu ISO URL"
        return @{ Url = $script:UbuntuISOUrl; Checksum = "sha256:$($script:UbuntuISOChecksum)" }
    }

    Write-Step "Resolving Ubuntu 24.04 ISO URL dynamically..."
    $hashPage = Invoke-WithRetry -MaxAttempts 6 -DelaySeconds 15 -Description 'Fetch Ubuntu SHA256SUMS' -Action {
        Invoke-RestMethod -Uri "$($script:UbuntuReleasesBaseUrl)/SHA256SUMS" `
                          -UseBasicParsing -TimeoutSec 30
    }
    # Find the server ISO line (version format: ubuntu-24.04.N-live-server-amd64.iso)
    $isoLine = $hashPage -split "`n" |
               Where-Object { $_.Trim() -match 'ubuntu-24\.\d+\.\d+-live-server-amd64\.iso' } |
               Select-Object -Last 1   # pick highest patch version if multiple

    if (-not $isoLine) {
        throw "Could not parse Ubuntu 24.04 SHA256SUMS from $($script:UbuntuReleasesBaseUrl)/SHA256SUMS"
    }

    $parts    = $isoLine.Trim() -split '\s+'
    $hash     = $parts[0]
    $filename = $parts[1] -replace '^\*', ''
    $url      = "$($script:UbuntuReleasesBaseUrl)/$filename"

    Write-Step "Resolved: $url  (sha256: $hash)"
    return @{ Url = $url; Checksum = "sha256:$hash" }
}

# ---------------------------------------------------------------------------
function New-SshKeyPair {
    if (Test-Path $script:SshKeyPath) { return }
    Write-Step "Generating ephemeral SSH key pair for Packer provisioning..."
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $script:SshKeyPath)
    ssh-keygen -t ed25519 -N '' -f $script:SshKeyPath -C 'packer-linux-build' | Out-Null
}

# ---------------------------------------------------------------------------
function Update-UserData {
    <#
        Replaces placeholders in user-data:
          __LINUX_ADMIN_PASS_HASH__  → bcrypt hash of LinuxAdminPass
          __SSH_PUBLIC_KEY__         → content of the ephemeral public key
        Each placeholder is handled independently so a re-run that already
        has the hash baked in still injects the SSH key (and vice versa).
    #>
    $userDataPath = Join-Path $script:PackerLinuxDir 'http\user-data'
    $content      = Get-Content $userDataPath -Raw
    $dirty        = $false

    # --- password hash ---
    if ($content -match '__LINUX_ADMIN_PASS_HASH__') {
        Write-Step "Generating bcrypt hash for Linux admin password..."
        $hash = $null
        $opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
        if ($opensslCmd) {
            $hash = (openssl passwd -6 $script:LinuxAdminPass 2>&1).Trim()
        }
        if (-not $hash -or $hash -like 'Error*') {
            $pyCmd = Get-Command python -ErrorAction SilentlyContinue
            if ($pyCmd) {
                $hash = (python -c "import crypt; print(crypt.crypt('$($script:LinuxAdminPass)', crypt.mksalt(crypt.METHOD_SHA512)))" 2>&1).Trim()
            }
        }
        if (-not $hash -or $hash -like '*Error*' -or $hash.Length -lt 20) {
            throw "Could not generate bcrypt/SHA-512 password hash. " +
                  "Install Git for Windows (includes openssl) or Python, then re-run."
        }
        $content = $content -replace '__LINUX_ADMIN_PASS_HASH__', $hash
        $dirty   = $true
        Write-Success "user-data: password hash injected"
    } else {
        Write-Step "user-data: password hash already set"
    }

    # --- SSH public key ---
    $pubKeyPath = "$($script:SshKeyPath).pub"
    if (-not (Test-Path $pubKeyPath)) {
        throw "SSH public key not found at '$pubKeyPath'. New-SshKeyPair must run first."
    }
    $pubKey = (Get-Content $pubKeyPath -Raw).Trim()

    if ($content -match '__SSH_PUBLIC_KEY__') {
        # First run: replace placeholder
        $content = $content -replace '__SSH_PUBLIC_KEY__', $pubKey
        $dirty   = $true
        Write-Success "user-data: SSH public key injected"
    } elseif ($content -notmatch [regex]::Escape($pubKey)) {
        # Key was previously baked in but doesn't match current key (e.g. after -OutputFiles rebuild).
        # Replace any packer-linux-build key lines in both authorized-keys sections.
        $content = $content -replace 'ssh-ed25519 [A-Za-z0-9+/=]+ packer-linux-build', $pubKey
        $dirty   = $true
        Write-Success "user-data: SSH public key updated (new key pair)"
    } else {
        Write-Step "user-data: SSH public key already set"
    }

    if ($dirty) {
        Set-Content -Path $userDataPath -Value $content -NoNewline
    }
}

# ---------------------------------------------------------------------------
function Test-Phase2Complete {
    if (-not (Test-PhaseComplete 'phase2')) { return $false }

    $vm = Get-VM -Name $script:LinuxVMName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') { return $false }

    # Quick SSH check
    $ip = Get-VMIPAddress -VMName $script:LinuxVMName -TimeoutSec 10
    if (-not $ip) { return $false }

    $result = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
                  -o ConnectTimeout=5 -i $script:SshKeyPath `
                  "$($script:LinuxAdminUser)@$ip" `
                  'systemctl is-active k3s' 2>&1
    # is-active exits 0 only when 'active'; 'activating' = exit 3
    return ($LASTEXITCODE -eq 0 -and ($result | Where-Object { $_ -is [string] }) -join '' -match 'active')
}

# ---------------------------------------------------------------------------
function Assert-Phase2Complete {
    Write-Step "Verifying Phase 2 (Linux VM + k3s)..."

    $vm = Get-VM -Name $script:LinuxVMName -ErrorAction SilentlyContinue
    Assert-True ($null -ne $vm) "VM '$($script:LinuxVMName)' does not exist" `
        'Re-run Build-LinuxVM.ps1 -Force'

    Assert-True ($vm.State -eq 'Running') "VM '$($script:LinuxVMName)' is not Running (state: $($vm.State))"

    $ip = Get-VMIPAddress -VMName $script:LinuxVMName -TimeoutSec 60
    Assert-True ($null -ne $ip -and $ip -ne '') "Could not obtain IP for '$($script:LinuxVMName)'"
    Write-Step "Linux VM IP: $ip"

    Wait-Until -TimeoutSec $script:VMBootTimeoutSec -PollSec 10 -Description 'SSH to respond' -Condition {
        $r = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
                 -o ConnectTimeout=5 -i $script:SshKeyPath `
                 "$($script:LinuxAdminUser)@$ip" 'echo ok' 2>&1
        return ($LASTEXITCODE -eq 0 -and ($r | Where-Object { $_ -is [string] }) -contains 'ok')
    }

    # k3s takes 30-60 s after first boot to initialise (loads images, starts API server).
    # Poll until `systemctl is-active k3s` returns exit 0 ('active').
    Wait-Until -TimeoutSec $script:K3sReadyTimeoutSec -PollSec 10 `
        -Description 'k3s service to become active' -Condition {
        $r = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
                 -o ConnectTimeout=10 -i $script:SshKeyPath `
                 "$($script:LinuxAdminUser)@$ip" 'systemctl is-active k3s' 2>&1
        return ($LASTEXITCODE -eq 0)
    }

    $nodeReady = Invoke-SshCommand -HostIp $ip -User $script:LinuxAdminUser `
                     -KeyPath $script:SshKeyPath `
                     -Command "sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo 0" -PassThru
    Assert-True ([int](($nodeReady | Where-Object { $_ -is [string] }) -join '' | ForEach-Object { $_.Trim() }) -ge 1) 'No k3s nodes are Ready'

    Write-Success "Phase 2 OK — Linux VM running, k3s active, node Ready"

    # Store IP for use by later phases
    $ipFile = Join-Path $script:OutputDir 'linux-vm-ip.txt'
    Set-Content -Path $ipFile -Value $ip.Trim()
}

# ---------------------------------------------------------------------------
function Invoke-Phase2 {
    Write-PhaseHeader '2' 'Build Linux VM (Ubuntu 24.04 + k3s server)'

    Assert-DiskSpace -Path $script:RepoRoot -MinimumGB 25

    Initialize-OutputDir $script:OutputDir
    New-SshKeyPair
    Update-UserData

    $iso = Get-UbuntuISO

    $vhdxDir  = Join-Path $script:VHDXStoreDir 'linux'
    $diskMB   = $script:DiskSizeGB * 1024
    $memMB    = $script:LinuxMemoryGB * 1024

    # Stop and unregister any leftover VM FIRST so the VHDX is not locked
    $existingVm = Get-VM -Name $script:LinuxVMName -ErrorAction SilentlyContinue
    if ($existingVm) {
        Write-Warn "Removing leftover VM '$($script:LinuxVMName)' from a previous run..."
        if ($existingVm.State -ne 'Off') {
            Stop-VM -Name $script:LinuxVMName -Force -TurnOff
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-VM -Name $script:LinuxVMName).State -ne 'Off') {
                if ((Get-Date) -gt $deadline) { throw "Timed out waiting for VM '$($script:LinuxVMName)' to stop" }
                Start-Sleep -Seconds 2
            }
        }
        Remove-VM -Name $script:LinuxVMName -Force
        Write-Success "Removed leftover VM '$($script:LinuxVMName)'"
    }

    # Now the VHDX is released — safe to delete stale Packer output
    if (Test-Path $vhdxDir) {
        Write-Warn "Removing stale Packer output directory: $vhdxDir"
        Remove-Item -Recurse -Force $vhdxDir
    }

    Invoke-Step 'Initialize Packer plugins' {
        Push-Location $script:PackerLinuxDir
        try {
            packer init .
            if ($LASTEXITCODE -ne 0) { throw "packer init failed with exit code $LASTEXITCODE" }
        }
        finally { Pop-Location }
    }

    Invoke-Step 'Run Packer build (Ubuntu)' {
        Push-Location $script:PackerLinuxDir
        try {
            $env:PACKER_LOG = 1
            $env:PACKER_LOG_PATH = Join-Path $script:OutputDir 'packer-linux.log'

            packer build `
                -var "vm_name=$($script:LinuxVMName)" `
                -var "cpu_count=$($script:LinuxCPU)" `
                -var "memory_mb=$memMB" `
                -var "disk_size_mb=$diskMB" `
                -var "switch_name=$($script:vSwitchName)" `
                -var "admin_user=$($script:LinuxAdminUser)" `
                -var "admin_pass=$($script:LinuxAdminPass)" `
                -var "iso_url=$($iso.Url)" `
                -var "iso_checksum=$($iso.Checksum)" `
                -var "output_dir=$vhdxDir" `
                -var "k3s_version=$($script:K3sVersion)" `
                -var "ssh_private_key_file=$($script:SshKeyPath)" `
                .

            if ($LASTEXITCODE -ne 0) {
                throw "packer build exited with code $LASTEXITCODE. See $($env:PACKER_LOG_PATH)"
            }
        }
        finally { Pop-Location }
    }

    # Packer hyperv-iso exports the VM to output_dir then UNREGISTERS the original.
    # Re-import in-place (no file copy) so Hyper-V knows about it, then start it.
    Invoke-Step 'Start Linux VM' {
        $existingVm = Get-VM -Name $script:LinuxVMName -ErrorAction SilentlyContinue
        if (-not $existingVm) {
            Write-Step "VM not registered — importing from Packer export at '$vhdxDir'..."
            $vmcx = Get-ChildItem -Path $vhdxDir -Recurse -Filter '*.vmcx' -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            if (-not $vmcx) {
                throw "No .vmcx config found under '$vhdxDir'. Check $($env:PACKER_LOG_PATH)"
            }
            Import-VM -Path $vmcx.FullName -Register
            $existingVm = Get-VM -Name $script:LinuxVMName -ErrorAction SilentlyContinue
            if (-not $existingVm) {
                throw "Import-VM ran but '$($script:LinuxVMName)' still not visible in Hyper-V"
            }
            Write-Success "VM imported from '$($vmcx.FullName)'"
        }
        if ($existingVm.State -ne 'Running') {
            Start-VM -Name $script:LinuxVMName
        }
    }

    Assert-Phase2Complete
    Set-PhaseComplete 'phase2'
    Write-PhaseDone '2'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($Force) { Reset-PhaseComplete 'phase2' }

if (Test-Phase2Complete) {
    Write-Success 'Phase 2 already complete — skipping'
} else {
    Invoke-Phase2
}
