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
        [string]$Description = 'condition'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return }
        Write-Step "Waiting for $Description..."
        Start-Sleep -Seconds $PollSec
    }
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
    Wait-Until -TimeoutSec $TimeoutSec -PollSec 5 -Description "$VMName IP assignment" -Condition {
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
