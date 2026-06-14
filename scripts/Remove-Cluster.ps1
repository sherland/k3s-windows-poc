# =============================================================================
# scripts/Remove-Cluster.ps1
# Cluster teardown / cleanup.  Idempotent — safe to run multiple times.
#
# USAGE
#   # Remove everything (VMs, vSwitch, VHDs, output files, sentinels, ISOs):
#   .\scripts\Remove-Cluster.ps1 -All
#
#   # Remove only the VMs and their VHD files:
#   .\scripts\Remove-Cluster.ps1 -VMs
#
#   # Remove only the Hyper-V virtual switch:
#   .\scripts\Remove-Cluster.ps1 -Network
#
#   # Remove only generated output files (kubeconfig, keys, logs, sentinels):
#   .\scripts\Remove-Cluster.ps1 -OutputFiles
#
#   # Remove only downloaded / cached large files (ISOs, Packer cache):
#   .\scripts\Remove-Cluster.ps1 -Downloads
#
#   # Combine flags freely:
#   .\scripts\Remove-Cluster.ps1 -VMs -Network -OutputFiles
#
#   # Dry-run: show what WOULD be removed without actually deleting anything:
#   .\scripts\Remove-Cluster.ps1 -All -WhatIf
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$All,           # shorthand for -VMs -Network -OutputFiles -Downloads
    [switch]$VMs,           # stop + delete Hyper-V VMs and their VHD/X files
    [switch]$Network,       # remove the k8s-external Hyper-V vSwitch
    [switch]$OutputFiles,   # remove generated output\ files and phase sentinels
    [switch]$Downloads,     # remove cached ISOs and Packer HTTP cache
    [switch]$Force          # skip confirmation prompts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Helpers.ps1"
. "$PSScriptRoot\..\config\variables.ps1"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Remove-VMAndDisks {
    param([string]$VMName)

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Warn "  VM '$VMName' not found — skipping."
        return
    }

    # Collect disk paths before VM is removed
    $diskPaths = @(
        Get-VMHardDiskDrive -VMName $VMName -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Path
    )

    if ($vm.State -ne 'Off') {
        Write-Step "  Stopping VM '$VMName'..."
        if ($PSCmdlet.ShouldProcess($VMName, 'Stop-VM -TurnOff')) {
            Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Step "  Removing VM '$VMName'..."
    if ($PSCmdlet.ShouldProcess($VMName, 'Remove-VM')) {
        Remove-VM -Name $VMName -Force
    }

    foreach ($disk in $diskPaths) {
        if ($disk -and (Test-Path $disk)) {
            Write-Step "  Removing disk: $disk"
            if ($PSCmdlet.ShouldProcess($disk, 'Remove-Item')) {
                Remove-Item $disk -Force
            }
        }
    }

    Write-Success "  VM '$VMName' removed."
}

function Remove-IfExists {
    param([string]$Path, [string]$Label)
    if (Test-Path $Path) {
        Write-Step "  Removing $Label`: $Path"
        if ($PSCmdlet.ShouldProcess($Path, 'Remove-Item')) {
            Remove-Item $Path -Recurse -Force
        }
    } else {
        Write-Warn "  $Label not found — skipping: $Path"
    }
}

# ---------------------------------------------------------------------------
# Expand -All
# ---------------------------------------------------------------------------
if ($All) {
    $VMs         = $true
    $Network     = $true
    $OutputFiles = $true
    $Downloads   = $true
}

if (-not ($VMs -or $Network -or $OutputFiles -or $Downloads)) {
    Write-Host @'
No cleanup target specified. Use one or more of:

  -All           Remove everything
  -VMs           Remove Hyper-V VMs and their VHD files
  -Network       Remove the k8s-external Hyper-V vSwitch
  -OutputFiles   Remove generated output files and phase sentinels
  -Downloads     Remove cached ISOs and Packer HTTP cache

Add -WhatIf to preview without making any changes.
'@
    exit 0
}

# ---------------------------------------------------------------------------
# Confirm unless -Force or -WhatIf
# ---------------------------------------------------------------------------
if (-not $Force -and -not $WhatIfPreference) {
    $targets = @()
    if ($VMs)         { $targets += "VMs ($($script:LinuxVMName), $($script:WindowsVMName)) + VHD files" }
    if ($Network)     { $targets += "Hyper-V vSwitch '$($script:vSwitchName)'" }
    if ($OutputFiles) { $targets += "output\ files and phase sentinels" }
    if ($Downloads)   { $targets += "cached ISOs and Packer HTTP cache" }

    Write-Host ''
    Write-Host 'The following will be PERMANENTLY REMOVED:' -ForegroundColor Yellow
    $targets | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host ''
    $answer = Read-Host 'Type YES to confirm'
    if ($answer -ne 'YES') {
        Write-Host 'Aborted.' -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
# VMs
# ---------------------------------------------------------------------------
if ($VMs) {
    Write-PhaseHeader 'CLEAN' 'Remove Hyper-V VMs'

    Remove-VMAndDisks -VMName $script:LinuxVMName
    Remove-VMAndDisks -VMName $script:WindowsVMName

    # Remove the VHDX store directories (they may still hold orphaned files)
    foreach ($sub in @('linux', 'windows')) {
        $dir = Join-Path $script:VHDXStoreDir $sub
        if (Test-Path $dir) {
            $remaining = Get-ChildItem $dir -ErrorAction SilentlyContinue
            if ($remaining) {
                Write-Step "  Removing remaining VHDX files in $dir"
                if ($PSCmdlet.ShouldProcess($dir, 'Remove VHDX files')) {
                    Remove-Item (Join-Path $dir '*') -Recurse -Force
                }
            }
        }
    }

    Write-Success 'VMs removed.'
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
if ($Network) {
    Write-PhaseHeader 'CLEAN' 'Remove Hyper-V vSwitch'

    $sw = Get-VMSwitch -Name $script:vSwitchName -ErrorAction SilentlyContinue
    if ($sw) {
        Write-Step "  Removing vSwitch '$($script:vSwitchName)'..."
        if ($PSCmdlet.ShouldProcess($script:vSwitchName, 'Remove-VMSwitch')) {
            Remove-VMSwitch -Name $script:vSwitchName -Force
        }
        Write-Success "  vSwitch '$($script:vSwitchName)' removed."
    } else {
        Write-Warn "  vSwitch '$($script:vSwitchName)' not found — skipping."
    }
}

# ---------------------------------------------------------------------------
# Output files (kubeconfig, SSH keys, logs, sentinels)
# ---------------------------------------------------------------------------
if ($OutputFiles) {
    Write-PhaseHeader 'CLEAN' 'Remove generated output files'

    $filesToRemove = @(
        'kubeconfig.yaml',
        'linux-build-key',
        'linux-build-key.pub',
        'linux-vm-ip.txt',
        'windows-vm-ip.txt',
        'cluster-info.txt',
        'run.log',
        'packer-linux.log',
        'packer-windows.log'
    )
    foreach ($f in $filesToRemove) {
        $path = Join-Path $script:OutputDir $f
        if (Test-Path $path) {
            Write-Step "  Removing $f"
            if ($PSCmdlet.ShouldProcess($path, 'Remove-Item')) {
                Remove-Item $path -Force
            }
        }
    }

    # Phase sentinels
    $sentinelDir = Join-Path $script:OutputDir 'sentinels'
    if (Test-Path $sentinelDir) {
        Write-Step "  Removing phase sentinels in $sentinelDir"
        if ($PSCmdlet.ShouldProcess($sentinelDir, 'Remove sentinel files')) {
            Remove-Item (Join-Path $sentinelDir '*') -Force -ErrorAction SilentlyContinue
        }
    }

    # Legacy TEMP sentinels (old location)
    foreach ($legacyDir in @(
        (Join-Path $env:TEMP 'k8s-hyperv-sentinels'),
        'C:\Windows\Temp\k8s-hyperv-sentinels'
    )) {
        if (Test-Path $legacyDir) {
            Write-Step "  Removing legacy sentinels in $legacyDir"
            if ($PSCmdlet.ShouldProcess($legacyDir, 'Remove-Item')) {
                Remove-Item $legacyDir -Recurse -Force
            }
        }
    }

    Write-Success 'Output files removed.'
}

# ---------------------------------------------------------------------------
# Downloads (ISOs, Packer HTTP cache)
# ---------------------------------------------------------------------------
if ($Downloads) {
    Write-PhaseHeader 'CLEAN' 'Remove cached downloads'

    # ISOs cached by Build-LinuxVM / Build-WindowsVM
    $isoGlobs = @(
        (Join-Path $script:OutputDir '*.iso'),
        (Join-Path $script:PackerLinuxDir 'http\*.iso'),
        (Join-Path $script:PackerWindowsDir 'http\*.iso')
    )
    foreach ($glob in $isoGlobs) {
        $files = Get-Item $glob -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            Write-Step "  Removing ISO: $($f.FullName)"
            if ($PSCmdlet.ShouldProcess($f.FullName, 'Remove-Item')) {
                Remove-Item $f.FullName -Force
            }
        }
    }

    # Windows ISO — may be stored at a custom path from variables.ps1
    if ($script:WindowsISOLocalPath -and (Test-Path $script:WindowsISOLocalPath)) {
        Write-Step "  Removing Windows ISO: $($script:WindowsISOLocalPath)"
        if ($PSCmdlet.ShouldProcess($script:WindowsISOLocalPath, 'Remove-Item')) {
            Remove-Item $script:WindowsISOLocalPath -Force
        }
    }

    # Packer HTTP directory contents (autoinstall seed files etc.)
    foreach ($httpDir in @(
        (Join-Path $script:PackerLinuxDir 'http'),
        (Join-Path $script:PackerWindowsDir 'http')
    )) {
        if (Test-Path $httpDir) {
            $contents = Get-ChildItem $httpDir -ErrorAction SilentlyContinue
            foreach ($item in $contents) {
                # Keep the directory itself; only wipe cached/generated content
                if ($item.Extension -in @('.iso', '.tmp', '.cache')) {
                    Write-Step "  Removing Packer cache file: $($item.FullName)"
                    if ($PSCmdlet.ShouldProcess($item.FullName, 'Remove-Item')) {
                        Remove-Item $item.FullName -Force
                    }
                }
            }
        }
    }

    Write-Success 'Downloads removed.'
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '========================================================================'  -ForegroundColor Magenta
Write-Host '  Cleanup complete.' -ForegroundColor Green
Write-Host '  To rebuild the cluster from scratch, run:' -ForegroundColor Cyan
Write-Host '    .\scripts\Main.ps1' -ForegroundColor Cyan
Write-Host '========================================================================'  -ForegroundColor Magenta
Write-Host ''
