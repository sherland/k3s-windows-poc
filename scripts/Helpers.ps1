# =============================================================================
# scripts/Helpers.ps1
# Shared utility functions used by all other scripts.
# Dot-source this file at the top of every script: . "$PSScriptRoot\Helpers.ps1"
# =============================================================================

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
function Write-Step {
    param([string]$Message)
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] OK  $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] WARN $Message" -ForegroundColor Yellow
}

function Write-PhaseHeader {
    param([string]$Phase, [string]$Description)
    $line = '=' * 72
    Write-Host ''
    Write-Host $line -ForegroundColor Magenta
    Write-Host "  PHASE $Phase — $Description" -ForegroundColor Magenta
    Write-Host $line -ForegroundColor Magenta
}

function Write-PhaseDone {
    param([string]$Phase)
    Write-Host "  Phase $Phase completed successfully." -ForegroundColor Green
    Write-Host ''
}

# -----------------------------------------------------------------------------
# Error handling with context
# -----------------------------------------------------------------------------
function Invoke-Step {
    <#
    .SYNOPSIS
        Runs a script block; on failure prints context and re-throws.
    #>
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    Write-Step $Name
    try {
        & $Action
        Write-Success $Name
    }
    catch {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       $_" -ForegroundColor Red
        throw
    }
}

# -----------------------------------------------------------------------------
# Disk space guard
# -----------------------------------------------------------------------------
function Assert-DiskSpace {
    param(
        [string]$Path = 'C:\',
        [int]$MinimumGB = 20
    )
    $drive = Split-Path -Qualifier $Path
    $disk  = Get-PSDrive -Name ($drive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if (-not $disk) {
        $disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$drive'" |
                Select-Object @{N='Free';E={$_.FreeSpace}}
        $freeGB = [math]::Round($disk.Free / 1GB, 1)
    } else {
        $freeGB = [math]::Round($disk.Free / 1GB, 1)
    }
    if ($freeGB -lt $MinimumGB) {
        throw "Insufficient disk space on $drive — ${freeGB} GB free, need at least ${MinimumGB} GB. Free up space and re-run."
    }
    Write-Step "Disk space OK: ${freeGB} GB free on $drive"
}

# -----------------------------------------------------------------------------
# Retry helper
# -----------------------------------------------------------------------------
function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [int]$MaxAttempts = 5,
        [int]$DelaySeconds = 10,
        [string]$Description = 'operation'
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return (& $Action)
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                throw "Failed $Description after $MaxAttempts attempts: $_"
            }
            Write-Warn "Attempt $attempt/$MaxAttempts failed for '$Description': $_  — retrying in ${DelaySeconds}s"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# -----------------------------------------------------------------------------
# Wait-Until helper
# -----------------------------------------------------------------------------
function Wait-Until {
    param(
        [scriptblock]$Condition,
        [int]$TimeoutSec = 300,
        [int]$PollSec    = 10,
        [string]$Description = 'condition',
        # When set, return $false on timeout instead of throwing
        [switch]$NoThrow
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Write-Step "Waiting for $Description..."
        Start-Sleep -Seconds $PollSec
    }
    if ($NoThrow) { return $false }
    throw "Timeout after ${TimeoutSec}s waiting for: $Description"
}

# -----------------------------------------------------------------------------
# Winget install helper
# -----------------------------------------------------------------------------
function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$DisplayName = $Id,
        [string]$BinaryName  = ''    # e.g. 'packer' — used to locate exe after install
    )
    Write-Step "Checking $DisplayName ($Id)..."

    # Check if already installed
    $installed = winget list --exact --id $Id --accept-source-agreements 2>&1
    $alreadyInstalled = ($LASTEXITCODE -eq 0 -and ($installed -match [regex]::Escape($Id)))

    if (-not $alreadyInstalled) {
        Write-Step "Installing $DisplayName via winget (machine scope)..."
        # --scope machine installs to Program Files (machine PATH) rather than user AppData
        winget install --exact --id $Id --scope machine `
            --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Machine-scope install failed; retrying without --scope (user scope)..."
            winget install --exact --id $Id `
                --accept-package-agreements --accept-source-agreements --silent
            if ($LASTEXITCODE -ne 0) {
                throw "winget install failed for $Id (exit code $LASTEXITCODE)"
            }
        }
    } else {
        Write-Success "$DisplayName already installed via winget"
    }

    # Refresh PATH in current session from both Machine and User scopes
    $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH    = ($machinePath + ';' + $userPath) -replace ';;+',';'

    # If the binary is still not found, locate it and add its dir to MACHINE PATH
    if ($BinaryName -and -not (Get-Command $BinaryName -ErrorAction SilentlyContinue)) {
        Write-Step "$BinaryName not on PATH yet — searching common winget install locations..."
        $searchRoots = @(
            "$env:ProgramFiles",
            "$env:ProgramFiles(x86)",
            "$env:LOCALAPPDATA\Microsoft\WinGet\Links",
            "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
            "C:\ProgramData\chocolatey\bin"
        )
        $found = $null
        foreach ($root in $searchRoots) {
            if (Test-Path $root) {
                $found = Get-ChildItem $root -Recurse -Filter "${BinaryName}.exe" `
                         -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) { break }
            }
        }
        if ($found) {
            $dir = $found.DirectoryName
            Write-Step "Found ${BinaryName}.exe at: $($found.FullName)"
            # Add to machine PATH permanently
            $mp = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
            if ($mp -notlike "*$dir*") {
                [System.Environment]::SetEnvironmentVariable('PATH', "$mp;$dir", 'Machine')
                Write-Step "Added $dir to Machine PATH"
            }
            $env:PATH = "$env:PATH;$dir"
        } else {
            throw "Installed $DisplayName but ${BinaryName}.exe could not be found. " +
                  "Open a new elevated terminal and re-run."
        }
    }

    Write-Success "$DisplayName installed and on PATH"
}

# -----------------------------------------------------------------------------
# SSH helper — run a command on a remote Linux VM
# -----------------------------------------------------------------------------
function Invoke-SshCommand {
    param(
        [string]$HostIp,
        [string]$User,
        [string]$KeyPath,
        [string]$Command,
        [switch]$PassThru
    )
    $sshArgs = @(
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-o', 'ConnectTimeout=10',
        '-i', $KeyPath,
        "$User@$HostIp",
        $Command
    )
    if ($PassThru) {
        $output = ssh @sshArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "SSH command failed (exit $LASTEXITCODE): $Command`nOutput: $output"
        }
        return $output
    } else {
        ssh @sshArgs
        if ($LASTEXITCODE -ne 0) {
            throw "SSH command failed (exit $LASTEXITCODE): $Command"
        }
    }
}

# -----------------------------------------------------------------------------
# SCP helper — copy a file from a remote Linux VM to the host
# -----------------------------------------------------------------------------
function Copy-SshFile {
    param(
        [string]$HostIp,
        [string]$User,
        [string]$KeyPath,
        [string]$RemotePath,
        [string]$LocalPath
    )
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $LocalPath)
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
        -i $KeyPath "$User@${HostIp}:$RemotePath" $LocalPath
    if ($LASTEXITCODE -ne 0) {
        throw "SCP failed: $RemotePath -> $LocalPath"
    }
}

# -----------------------------------------------------------------------------
# Get the first IP assigned to a running Hyper-V VM
# -----------------------------------------------------------------------------
function Get-VMIPAddress {
    param(
        [string]$VMName,
        [int]$TimeoutSec = 120
    )
    $null = Wait-Until -TimeoutSec $TimeoutSec -PollSec 5 -Description "$VMName IP assignment" -Condition {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if (-not $vm) { return $false }
        $ip = ($vm.NetworkAdapters | ForEach-Object { $_.IPAddresses } |
               Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.*' } |
               Select-Object -First 1)
        return ($null -ne $ip -and $ip -ne '')
    }

    $vm = Get-VM -Name $VMName
    return ($vm.NetworkAdapters | ForEach-Object { $_.IPAddresses } |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.*' } |
            Select-Object -First 1)
}

# -----------------------------------------------------------------------------
# Assert a condition or throw
# -----------------------------------------------------------------------------
function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message,
        [string]$Remediation = ''
    )
    if (-not $Condition) {
        $msg = "ASSERTION FAILED: $Message"
        if ($Remediation) { $msg += "`nRemediation: $Remediation" }
        throw $msg
    }
}

# -----------------------------------------------------------------------------
# Sentinel file helpers — used to mark phases as complete across re-runs
# -----------------------------------------------------------------------------
function Get-SentinelPath {
    param([string]$Phase)
    # Use a fixed path under the repo output dir so elevated and non-elevated
    # sessions both see the same sentinels (avoids $env:TEMP divergence).
    $dir = Join-Path $script:RepoRoot 'output\sentinels'
    $null = New-Item -ItemType Directory -Force -Path $dir
    return Join-Path $dir "phase-${Phase}.done"
}

function Test-PhaseComplete {
    param([string]$Phase)
    return (Test-Path (Get-SentinelPath $Phase))
}

function Set-PhaseComplete {
    param([string]$Phase)
    $path = Get-SentinelPath $Phase
    Set-Content -Path $path -Value (Get-Date -Format 'o')
}

function Reset-PhaseComplete {
    param([string]$Phase)
    $path = Get-SentinelPath $Phase
    if (Test-Path $path) { Remove-Item $path -Force }
}

# -----------------------------------------------------------------------------
# Resolve latest GitHub release version
# -----------------------------------------------------------------------------
function Get-LatestGitHubRelease {
    param([string]$Repo)   # e.g. 'containerd/containerd'
    $uri  = "https://api.github.com/repos/$Repo/releases/latest"
    $resp = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'k8s-hyperv-builder' }
    return $resp.tag_name -replace '^v', ''
}

# -----------------------------------------------------------------------------
# Ensure output directory exists
# -----------------------------------------------------------------------------
function Initialize-OutputDir {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) {
        $null = New-Item -ItemType Directory -Force -Path $Dir
        Write-Step "Created output directory: $Dir"
    }
}

# =============================================================================
# Multi-node topology helpers
# =============================================================================

# Returns all Linux node VM names: CP first, then workers
function Get-AllLinuxNodeNames {
    $names = @($script:ControlPlaneVMName)
    for ($i = 1; $i -le $script:LinuxWorkerCount; $i++) {
        $names += '{0}-{1:D2}' -f $script:LinuxWorkerPrefix, $i
    }
    return $names
}

# Returns all Windows node VM names in order (numbered globally across specs)
function Get-AllWindowsNodeNames {
    $names  = @()
    $global = 1
    foreach ($spec in $script:WindowsNodeSpecs) {
        for ($i = 0; $i -lt $spec.Count; $i++) {
            $names += '{0}-{1:D2}' -f $script:WindowsWorkerPrefix, $global
            $global++
        }
    }
    return $names
}

# Returns hashtable: VMName → @{ OSVersion; CPU; RAM }
function Get-WindowsNodeOSMap {
    $map    = @{}
    $global = 1
    foreach ($spec in $script:WindowsNodeSpecs) {
        for ($i = 0; $i -lt $spec.Count; $i++) {
            $name        = '{0}-{1:D2}' -f $script:WindowsWorkerPrefix, $global
            $map[$name]  = @{ OSVersion = $spec.OSVersion; CPU = $spec.CPU; RAM = $spec.RAM }
            $global++
        }
    }
    return $map
}

# Returns the set of distinct OS versions needed (e.g. @('2022','2025') or @('2025'))
function Get-RequiredWindowsVersions {
    return @($script:WindowsNodeSpecs | ForEach-Object { $_.OSVersion } | Sort-Object -Unique)
}

# =============================================================================
# VHDX path helpers
# =============================================================================

# Return the path to the golden (parent) VHDX for a given OS type.
# The .vhdx is searched recursively under the OS-specific subdirectory.
function Get-BaseVhdxPath {
    param([string]$OS)   # 'linux' | 'win2022' | 'win2025'
    $subDir = switch ($OS) {
        'linux'   { 'linux-base' }
        'win2022' { 'win2022-base' }
        'win2025' { 'win2025-base' }
        default   { throw "Get-BaseVhdxPath: unknown OS '$OS'" }
    }
    $dir  = Join-Path $script:VHDXStoreDir $subDir
    $vhdx = Get-ChildItem -Path $dir -Recurse -Filter '*.vhdx' -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if (-not $vhdx) {
        throw "No .vhdx found under '$dir'. Run the base build first (Build-LinuxBase.ps1 or Build-WindowsBase.ps1)."
    }
    return $vhdx.FullName
}

# Return the canonical path for a node's differencing VHDX
function Get-NodeVhdxPath {
    param([string]$NodeName)
    return Join-Path $script:VHDXStoreDir "nodes\${NodeName}.vhdx"
}

# =============================================================================
# Differencing disk + VM creation
# =============================================================================

function New-DifferencingNode {
    <#
    .SYNOPSIS
        Create a Hyper-V VM backed by a differencing disk from a golden parent VHDX.
    .PARAMETER Generation
        2 = Linux (SCSI, UEFI, no secure boot). 1 = Windows (IDE, BIOS).
    #>
    param(
        [string]$VMName,
        [string]$ParentVhdxPath,
        [string]$ChildVhdxPath,
        [int]$CPU,
        [int]$MemoryMB,
        [string]$SwitchName,
        [int]$Generation = 2,
        [switch]$EnableNestedVirt
    )

    # Create differencing disk
    $childDir = Split-Path $ChildVhdxPath
    $null = New-Item -ItemType Directory -Force -Path $childDir

    if (-not (Test-Path $ChildVhdxPath)) {
        Write-Step "Creating differencing disk for '$VMName'..."
        New-VHD -Path $ChildVhdxPath -ParentPath $ParentVhdxPath -Differencing | Out-Null
        Write-Success "Differencing disk: $ChildVhdxPath"
    } else {
        Write-Step "Differencing disk already exists — reusing: $(Split-Path $ChildVhdxPath -Leaf)"
    }

    # Create the VM if it doesn't exist
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Step "Creating VM '$VMName' (Gen $Generation, ${MemoryMB} MB, $CPU vCPU)..."
        $null = New-VM -Name $VMName -Generation $Generation `
            -MemoryStartupBytes ($MemoryMB * 1MB) -SwitchName $SwitchName -NoVHD

        Set-VMProcessor -VMName $VMName -Count $CPU
        Set-VM         -VMName $VMName -DynamicMemory:$false -CheckpointType Disabled

        if ($Generation -eq 2) {
            Add-VMHardDiskDrive -VMName $VMName -Path $ChildVhdxPath -ControllerType SCSI
            Set-VMFirmware      -VMName $VMName -EnableSecureBoot Off
            # Set boot order: hard disk first, then network
            $hd  = Get-VMHardDiskDrive -VMName $VMName
            $net = Get-VMNetworkAdapter -VMName $VMName
            Set-VMFirmware -VMName $VMName -BootOrder @($hd, $net)
        } else {
            # Gen 1: IDE controller 0, position 0
            Add-VMHardDiskDrive -VMName $VMName -Path $ChildVhdxPath `
                -ControllerType IDE -ControllerNumber 0 -ControllerLocation 0
        }

        if ($EnableNestedVirt) {
            Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true
            Write-Step "Nested virtualisation enabled on '$VMName'"
        }

        Write-Success "VM '$VMName' created"
    } else {
        Write-Step "VM '$VMName' already registered — skipping creation"
    }
}

# =============================================================================
# Cloud-init seed ISO (Linux NoCloud datasource)
# =============================================================================

function Find-Oscdimg {
    # Prefer PATH
    $cmd = Get-Command oscdimg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Common ADK install locations
    $paths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\11\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    throw 'oscdimg.exe not found. Install Windows ADK: winget install --exact --id Microsoft.WindowsADK'
}

function New-SeedISO {
    <#
    .SYNOPSIS
        Create a cloud-init NoCloud seed ISO with CIDATA volume label.
    .PARAMETER UserDataContent
        Full #cloud-config YAML content (the user-data file).
    #>
    param(
        [string]$NodeName,
        [string]$IsoPath,
        [string]$UserDataContent,
        [string]$InstanceId = [Guid]::NewGuid().ToString()
    )

    $oscdimg = Find-Oscdimg

    $tmpDir = Join-Path $env:TEMP "cloud-init-$NodeName-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $null   = New-Item -ItemType Directory -Force -Path $tmpDir

    try {
        # meta-data: instance identity (required by NoCloud datasource)
        Set-Content -Path (Join-Path $tmpDir 'meta-data') -Encoding UTF8 -NoNewline `
            -Value "instance-id: $InstanceId`nlocal-hostname: $NodeName"

        # user-data: cloud-config
        Set-Content -Path (Join-Path $tmpDir 'user-data') -Encoding UTF8 -NoNewline `
            -Value $UserDataContent

        $null = New-Item -ItemType Directory -Force -Path (Split-Path $IsoPath)
        & $oscdimg -j1 -r -lcidata $tmpDir $IsoPath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "oscdimg failed creating '$IsoPath' (exit $LASTEXITCODE)"
        }
        Write-Success "Seed ISO created: $IsoPath"
    } finally {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Attach a seed ISO as a Gen2 SCSI DVD drive and set boot order (HD first)
function Add-SeedISOToDvd {
    param([string]$VMName, [string]$IsoPath)
    # Remove any existing DVD drives first
    Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue | Remove-VMDvdDrive
    Add-VMDvdDrive -VMName $VMName -Path $IsoPath
    # Re-assert boot order: HD, then DVD, then NIC
    $hd  = Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1
    $dvd = Get-VMDvdDrive      -VMName $VMName | Select-Object -First 1
    $net = Get-VMNetworkAdapter -VMName $VMName | Select-Object -First 1
    Set-VMFirmware -VMName $VMName -BootOrder @($hd, $dvd, $net)
    Write-Step "Seed ISO attached to '$VMName': $(Split-Path $IsoPath -Leaf)"
}

# =============================================================================
# SSH upload helper (host → remote Linux VM)
# =============================================================================
function Send-SshFile {
    param(
        [string]$HostIp,
        [string]$User,
        [string]$KeyPath,
        [string]$LocalPath,
        [string]$RemotePath
    )
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
        -i $KeyPath $LocalPath "${User}@${HostIp}:$RemotePath"
    if ($LASTEXITCODE -ne 0) {
        throw "SCP upload failed: $LocalPath → ${User}@${HostIp}:$RemotePath"
    }
}
