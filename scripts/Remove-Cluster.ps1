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
    [switch]$All,             # shorthand for -VMs -Network -OutputFiles -Downloads
    [switch]$VMs,             # stop + delete Hyper-V VMs and their VHD/X files
    [switch]$Network,         # remove the k8s-external Hyper-V vSwitch
    [switch]$OutputFiles,     # remove generated output\ files and phase sentinels
    [switch]$Downloads,       # remove cached ISOs and Packer HTTP cache
    [switch]$KeepBaseImages,  # with -VMs/-OutputFiles: keep golden base VHDXs and their sentinels
    [switch]$Force            # skip confirmation prompts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -Force suppresses ShouldProcess confirmations (ConfirmImpact = High blocks otherwise)
if ($Force) { $ConfirmPreference = 'None' }

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

  -All              Remove everything
  -VMs              Remove Hyper-V VMs and their VHD files
  -Network          Remove the k8s-external Hyper-V vSwitch
  -OutputFiles      Remove generated output files and phase sentinels
  -Downloads        Remove cached ISOs and Packer HTTP cache
  -KeepBaseImages   With -VMs/-OutputFiles: keep golden base VHDXs and their sentinels

Add -WhatIf to preview without making any changes.
'@
    exit 0
}

# ---------------------------------------------------------------------------
# Confirm unless -Force or -WhatIf
# ---------------------------------------------------------------------------
if (-not $Force -and -not $WhatIfPreference) {
    $targets = @()
        $allLinux   = Get-AllLinuxNodeNames
        $allWindows = Get-AllWindowsNodeNames
        $allVMs = $allLinux + $allWindows
        if ($VMs)         { $targets += "VMs ($($allVMs -join ', ')) + differencing VHD files" }
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
    Write-PhaseHeader 'CLEAN' 'Remove Hyper-V VMs and base images'

    # --- Upfront sweep: stop+remove ALL VMs that have any disk under our VHDX store ---
    # This handles differencing-disk chains: a running child locks its parent VHDX even
    # if the child's disk is in a different sub-directory (e.g. nodes\ vs win2022-base\).
    Get-VM -ErrorAction SilentlyContinue | ForEach-Object {
        $vmName = $_.Name
        $inStore = Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue |
                   Where-Object { $_.Path -like "$($script:VHDXStoreDir)\*" }
        if ($inStore) {
            Write-Step "  Found VM '$vmName' with disk in VHDX store — removing..."
            if ($PSCmdlet.ShouldProcess($vmName, 'Remove VM (VHDX store)')) {
                if ($_.State -ne 'Off') {
                    Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
                }
                # Collect disk paths before removing VM
                $diskPaths = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue |
                               Select-Object -ExpandProperty Path)
                Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue
                foreach ($disk in $diskPaths) {
                    if ($disk -and (Test-Path $disk)) {
                        Remove-Item $disk -Force -ErrorAction SilentlyContinue
                    }
                }
                Write-Success "  VM '$vmName' removed."
            }
        }
    }

    # Also remove any named base VMs that may not have disks in the store (edge case)
    if (-not $KeepBaseImages) {
        foreach ($baseName in @('k8s-linux-base', 'k8s-win2022-base', 'k8s-win2025-base')) {
            $bv = Get-VM -Name $baseName -ErrorAction SilentlyContinue
            if ($bv) { Remove-VMAndDisks -VMName $baseName }
        }
    }

    # Remove all VHDX store subdirectories
    $baseDirs = if ($KeepBaseImages) { @('nodes') } else { @('linux-base', 'win2022-base', 'win2025-base', 'nodes') }
    foreach ($sub in $baseDirs) {
        $dir = Join-Path $script:VHDXStoreDir $sub
        if (-not (Test-Path $dir)) { continue }
        Write-Step "  Removing VHDX dir: $dir"
        if ($PSCmdlet.ShouldProcess($dir, 'Remove-Item')) {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $dir) {
                # Retry once after brief pause (VMMS may hold handle momentarily)
                Start-Sleep -Seconds 3
                Remove-Item $dir -Recurse -Force
            }
        }
    }

    # Also remove legacy single-VM dirs (backward compat)
    # First, stop+remove any Hyper-V VMs still referencing VHDXs in these dirs
    foreach ($sub in @('linux', 'windows')) {
        $dir = Join-Path $script:VHDXStoreDir $sub
        if (-not (Test-Path $dir)) { continue }
        # Find VMs whose disks live under this dir
        Get-VM -ErrorAction SilentlyContinue | ForEach-Object {
            $vmName = $_.Name
            $vmDisks = Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue |
                       Where-Object { $_.Path -like "$dir\*" }
            if ($vmDisks) {
                Write-Step "  Stopping+removing legacy VM '$vmName' (disk in $dir)..."
                if ($PSCmdlet.ShouldProcess($vmName, 'Remove legacy VM')) {
                    Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
                    Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue
                }
            }
        }
        $remaining = Get-ChildItem $dir -ErrorAction SilentlyContinue
        if ($remaining) {
            Write-Step "  Removing legacy VHDX dir: $dir"
            if ($PSCmdlet.ShouldProcess($dir, 'Remove VHDX dir')) {
                Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
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
        if ($KeepBaseImages) {
            # Remove all sentinels except base-image ones
            $basesentinels = @('phase-linux-base.done','phase-win2022-base.done','phase-win2025-base.done')
            Write-Step "  Removing phase sentinels (keeping base-image sentinels)"
            Get-ChildItem $sentinelDir -Filter '*.done' | Where-Object { $_.Name -notin $basesentinels } | ForEach-Object {
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove-Item')) { Remove-Item $_.FullName -Force }
            }
        } else {
            Write-Step "  Removing phase sentinels in $sentinelDir"
            if ($PSCmdlet.ShouldProcess($sentinelDir, 'Remove sentinel files')) {
                Remove-Item (Join-Path $sentinelDir '*') -Force -ErrorAction SilentlyContinue
            }
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

    # ISOs cached by base builds
    $isoGlobs = @(
        (Join-Path $script:PackerWindowsDir 'iso\WS2022-eval.iso'),
        (Join-Path $script:PackerWindowsDir 'iso\WS2025-eval.iso')
    )
    foreach ($isoPath in $isoGlobs) {
        if (Test-Path $isoPath) {
            Write-Step "  Removing ISO: $isoPath"
            if ($PSCmdlet.ShouldProcess($isoPath, 'Remove-Item')) {
                Remove-Item $isoPath -Force
            }
        }
    }

    # Custom local ISO paths from variables.ps1
    foreach ($isoLocalPath in @($script:WindowsISOLocalPath2022, $script:WindowsISOLocalPath2025)) {
        if ($isoLocalPath -and (Test-Path $isoLocalPath)) {
            Write-Step "  Removing local ISO: $isoLocalPath"
            if ($PSCmdlet.ShouldProcess($isoLocalPath, 'Remove-Item')) {
                Remove-Item $isoLocalPath -Force
            }
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
