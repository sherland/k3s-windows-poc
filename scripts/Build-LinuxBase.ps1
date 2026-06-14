# =============================================================================
# scripts/Build-LinuxBase.ps1
# Phase 2 — Build the Ubuntu 24.04 golden base VHDX with Packer.
#
# The base image contains: OS packages, kernel tweaks, k3s binary, containerd.
# It does NOT configure k3s as server or agent (that happens later).
# The build ends with `cloud-init clean` so that each differencing-disk clone
# gets a fresh cloud-init identity from its per-node seed ISO.
#
# Sentinel: linux-base.done
# VHDX output: vhdx/linux-base/
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

$BaseVMName  = 'k8s-linux-base'   # Packer build VM name (temporary; unregistered after build)
$BaseVhdxDir = Join-Path $script:VHDXStoreDir 'linux-base'

# ---------------------------------------------------------------------------
function Get-UbuntuISO {
    if ($script:UbuntuISOUrl -and $script:UbuntuISOChecksum) {
        Write-Step "Using configured Ubuntu ISO URL"
        return @{ Url = $script:UbuntuISOUrl; Checksum = "sha256:$($script:UbuntuISOChecksum)" }
    }

    Write-Step "Resolving Ubuntu 24.04 ISO URL dynamically..."
    $hashPage = Invoke-WithRetry -MaxAttempts 6 -DelaySeconds 15 -Description 'Fetch Ubuntu SHA256SUMS' -Action {
        Invoke-RestMethod -Uri "$($script:UbuntuReleasesBaseUrl)/SHA256SUMS" `
                          -UseBasicParsing -TimeoutSec 30
    }
    $isoLine = $hashPage -split "`n" |
               Where-Object { $_.Trim() -match 'ubuntu-24\.\d+\.\d+-live-server-amd64\.iso' } |
               Select-Object -Last 1

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
        Replaces placeholders in user-data for the base Packer build:
          __LINUX_ADMIN_PASS_HASH__  → bcrypt/SHA-512 hash of LinuxAdminPass
          __SSH_PUBLIC_KEY__         → ephemeral public key content
        The hostname in user-data stays as 'k8s-linux-base' — per-node
        hostnames are set later via cloud-init seed ISOs.
    #>
    $userDataPath = Join-Path $script:PackerLinuxDir 'http\user-data'
    $content      = Get-Content $userDataPath -Raw
    $dirty        = $false

    # Password hash
    if ($content -match '__LINUX_ADMIN_PASS_HASH__') {
        Write-Step "Generating bcrypt/SHA-512 hash for Linux admin password..."
        $hash = $null
        if (Get-Command openssl -ErrorAction SilentlyContinue) {
            $hash = (openssl passwd -6 $script:LinuxAdminPass 2>&1).Trim()
        }
        if (-not $hash -or $hash -like 'Error*') {
            if (Get-Command python -ErrorAction SilentlyContinue) {
                $hash = (python -c "import crypt; print(crypt.crypt('$($script:LinuxAdminPass)', crypt.mksalt(crypt.METHOD_SHA512)))" 2>&1).Trim()
            }
        }
        if (-not $hash -or $hash -like '*Error*' -or $hash.Length -lt 20) {
            throw "Could not generate password hash. Install Git for Windows (includes openssl) or Python, then re-run."
        }
        $content = $content -replace '__LINUX_ADMIN_PASS_HASH__', $hash
        $dirty   = $true
        Write-Success "user-data: password hash injected"
    } else {
        Write-Step "user-data: password hash already set"
    }

    # SSH public key
    $pubKeyPath = "$($script:SshKeyPath).pub"
    if (-not (Test-Path $pubKeyPath)) {
        throw "SSH public key not found at '$pubKeyPath'. New-SshKeyPair must run first."
    }
    $pubKey = (Get-Content $pubKeyPath -Raw).Trim()

    if ($content -match '__SSH_PUBLIC_KEY__') {
        $content = $content -replace '__SSH_PUBLIC_KEY__', $pubKey
        $dirty   = $true
        Write-Success "user-data: SSH public key injected"
    } elseif ($content -notmatch [regex]::Escape($pubKey)) {
        # Key changed (e.g. after -OutputFiles rebuild) — replace any packer-linux-build line
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
function Test-LinuxBaseDone {
    if (-not (Test-PhaseComplete 'linux-base')) { return $false }
    try {
        $null = Get-BaseVhdxPath 'linux'
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------------------
function Invoke-LinuxBase {
    Write-PhaseHeader 'BASE-L' 'Build Linux golden base image (Ubuntu 24.04 + k3s binary)'

    Assert-DiskSpace -Path $script:RepoRoot -MinimumGB 25
    Initialize-OutputDir $script:OutputDir
    New-SshKeyPair
    Update-UserData

    $iso    = Get-UbuntuISO
    $diskMB = $script:DiskSizeGB * 1024
    $memMB  = $script:ControlPlaneRAM   # use CP RAM for the base build VM

    # Remove any leftover base VM (VHDX might be locked)
    $existingVm = Get-VM -Name $BaseVMName -ErrorAction SilentlyContinue
    if ($existingVm) {
        Write-Warn "Removing leftover base VM '$BaseVMName' from a previous run..."
        if ($existingVm.State -ne 'Off') { Stop-VM -Name $BaseVMName -Force -TurnOff }
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-VM -Name $BaseVMName).State -ne 'Off') {
            if ((Get-Date) -gt $deadline) { throw "Timed out waiting for '$BaseVMName' to stop" }
            Start-Sleep -Seconds 2
        }
        Remove-VM -Name $BaseVMName -Force
    }

    # Remove stale Packer output
    if (Test-Path $BaseVhdxDir) {
        Write-Warn "Removing stale base VHDX directory: $BaseVhdxDir"
        Remove-Item -Recurse -Force $BaseVhdxDir
    }

    Invoke-Step 'Initialize Packer plugins' {
        Push-Location $script:PackerLinuxDir
        try {
            packer init .
            if ($LASTEXITCODE -ne 0) { throw "packer init failed (exit $LASTEXITCODE)" }
        } finally { Pop-Location }
    }

    Invoke-Step 'Run Packer build (Linux base image)' {
        Push-Location $script:PackerLinuxDir
        try {
            $env:PACKER_LOG      = 1
            $env:PACKER_LOG_PATH = Join-Path $script:OutputDir 'packer-linux-base.log'

            packer build `
                -var "vm_name=$BaseVMName" `
                -var "cpu_count=$($script:ControlPlaneCPU)" `
                -var "memory_mb=$memMB" `
                -var "disk_size_mb=$diskMB" `
                -var "switch_name=$($script:vSwitchName)" `
                -var "admin_user=$($script:LinuxAdminUser)" `
                -var "admin_pass=$($script:LinuxAdminPass)" `
                -var "iso_url=$($iso.Url)" `
                -var "iso_checksum=$($iso.Checksum)" `
                -var "output_dir=$BaseVhdxDir" `
                -var "k3s_version=$($script:K3sVersion)" `
                -var "ssh_private_key_file=$($script:SshKeyPath)" `
                .

            if ($LASTEXITCODE -ne 0) {
                throw "packer build exited with code $LASTEXITCODE. See $($env:PACKER_LOG_PATH)"
            }
        } finally { Pop-Location }
    }

    # Packer hyperv-iso exports + unregisters the VM. The VHDX remains in $BaseVhdxDir.
    # Mark it read-only so differencing children can safely reference it.
    Invoke-Step 'Mark base VHDX read-only (protects parent for differencing children)' {
        $vhdx = Get-ChildItem -Path $BaseVhdxDir -Recurse -Filter '*.vhdx' | Select-Object -First 1
        Assert-True ($null -ne $vhdx) "No .vhdx found under '$BaseVhdxDir' after Packer build."
        Set-ItemProperty -Path $vhdx.FullName -Name IsReadOnly -Value $true
        Write-Success "Read-only: $($vhdx.FullName)"
    }

    # Verify the base VHDX is there before setting the sentinel
    $baseVhdxPath = Get-BaseVhdxPath 'linux'
    Write-Success "Linux base VHDX: $baseVhdxPath"

    Set-PhaseComplete 'linux-base'
    Write-PhaseDone 'BASE-L'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($Force) { Reset-PhaseComplete 'linux-base' }

if (Test-LinuxBaseDone) {
    Write-Success 'Linux base image already built — skipping'
} else {
    Invoke-LinuxBase
}
