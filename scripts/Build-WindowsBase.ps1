# =============================================================================
# scripts/Build-WindowsBase.ps1
# Phase 3 — Build Windows Server golden base VHDXs (one per required OS version).
#
# For each OS version referenced in $script:WindowsNodeSpecs:
#   1. Download the eval ISO if not already present.
#   2. Run Packer to build a base image with Containers feature, containerd,
#      and all k8s binaries installed (kubelet, kube-proxy, flanneld, CNI).
#      A first-boot script template and scheduled task are registered in the
#      image; the actual kubeconfig/token are injected per-node in Phase 7.
#   3. Mark the base VHDX read-only.
#
# Sentinels: win2022-base.done, win2025-base.done
# VHDX outputs: vhdx/win2022-base/, vhdx/win2025-base/
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

# ---------------------------------------------------------------------------
function Get-IsoConfig {
    param([string]$OSVersion)
    switch ($OSVersion) {
        '2022' {
            return @{
                EvalUrl   = $script:WindowsEvalUrl2022
                LocalPath = $script:WindowsISOLocalPath2022
                IsoFile   = Join-Path $script:PackerWindowsDir 'iso\WS2022-eval.iso'
                BaseVMName = 'k8s-win2022-base'
                VhdxDir   = Join-Path $script:VHDXStoreDir 'win2022-base'
                Sentinel  = 'win2022-base'
            }
        }
        '2025' {
            return @{
                EvalUrl   = $script:WindowsEvalUrl2025
                LocalPath = $script:WindowsISOLocalPath2025
                IsoFile   = Join-Path $script:PackerWindowsDir 'iso\WS2025-eval.iso'
                BaseVMName = 'k8s-win2025-base'
                VhdxDir   = Join-Path $script:VHDXStoreDir 'win2025-base'
                Sentinel  = 'win2025-base'
            }
        }
        default { throw "Unknown Windows OS version: '$OSVersion'. Use '2022' or '2025'." }
    }
}

# ---------------------------------------------------------------------------
function Invoke-ISODownload {
    param([hashtable]$Cfg, [string]$OSVersion)

    $isoPath = $Cfg.IsoFile
    $null    = New-Item -ItemType Directory -Force -Path (Split-Path $isoPath)

    if ((Test-Path $isoPath) -and (Get-Item $isoPath).Length -gt 1GB) {
        Write-Success "WS${OSVersion} ISO already present: $isoPath"
        return
    }

    if ($Cfg.LocalPath -and (Test-Path $Cfg.LocalPath)) {
        Write-Step "Using configured local ISO: $($Cfg.LocalPath)"
        Copy-Item $Cfg.LocalPath $isoPath -Force
        return
    }

    Assert-DiskSpace -Path $script:RepoRoot -MinimumGB 8
    Write-Step "Downloading Windows Server ${OSVersion} Eval ISO (~5 GB)..."
    Write-Warn  "Ensure stable internet connectivity."

    Invoke-Step "Download WS${OSVersion} ISO via curl" {
        curl.exe -fsSL -L --max-redirs 10 -o $isoPath $Cfg.EvalUrl
        if ($LASTEXITCODE -ne 0) {
            Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
            throw "curl download failed (exit $LASTEXITCODE). Set WindowsISOLocalPath${OSVersion} in config/variables.ps1."
        }
    }

    $size = (Get-Item $isoPath).Length
    if ($size -lt 1GB) {
        Remove-Item $isoPath -Force
        throw "Downloaded file is too small ($([math]::Round($size/1MB)) MB). Microsoft Eval Center download likely failed. " +
              "Download manually and set WindowsISOLocalPath${OSVersion} in config/variables.ps1."
    }
    Write-Success "WS${OSVersion} ISO downloaded: $([math]::Round($size/1GB,1)) GB"
}

# ---------------------------------------------------------------------------
function Invoke-WindowsBaseForVersion {
    param([string]$OSVersion)

    $cfg       = Get-IsoConfig -OSVersion $OSVersion
    $sentinel  = $cfg.Sentinel
    $baseVMName = $cfg.BaseVMName
    $vhdxDir   = $cfg.VhdxDir

    if (-not $Force -and (Test-PhaseComplete $sentinel)) {
        try {
            $null = Get-BaseVhdxPath "win${OSVersion}"
            Write-Success "WS${OSVersion} base already built — skipping"
            return
        } catch { }
    }

    Write-PhaseHeader "BASE-W${OSVersion}" "Build Windows Server ${OSVersion} golden base image"
    Assert-DiskSpace -Path $script:RepoRoot -MinimumGB 30

    Invoke-ISODownload -Cfg $cfg -OSVersion $OSVersion

    # Prepare autounattend (inject admin password into the version-specific copy)
    $xmlPath = Join-Path $script:PackerWindowsDir "autounattend\$OSVersion\autounattend.xml"
    if (-not (Test-Path $xmlPath)) {
        throw "autounattend XML not found at '$xmlPath'. Expected per-version files."
    }
    $xmlContent = Get-Content $xmlPath -Raw
    if ($xmlContent -match '__WIN_ADMIN_PASS__') {
        $xmlContent = $xmlContent -replace '__WIN_ADMIN_PASS__', $script:WinAdminPass
        Set-Content -Path $xmlPath -Value $xmlContent -NoNewline
        Write-Step "autounattend.xml (WS${OSVersion}): admin password injected"
    }

    # Remove stale base VM + VHDX
    $existingVm = Get-VM -Name $baseVMName -ErrorAction SilentlyContinue
    if ($existingVm) {
        Write-Warn "Removing leftover base VM '$baseVMName'..."
        if ($existingVm.State -ne 'Off') { Stop-VM -Name $baseVMName -Force -TurnOff }
        Remove-VM -Name $baseVMName -Force
    }
    if (Test-Path $vhdxDir) {
        Write-Warn "Removing stale Packer output: $vhdxDir"
        Remove-Item -Recurse -Force $vhdxDir
    }

    # Resolve containerd version
    $ctrdVersion = $script:ContainerdVersion
    if ($ctrdVersion -eq 'latest') {
        $ctrdVersion = Get-LatestGitHubRelease -Repo 'containerd/containerd'
        Write-Step "Resolved containerd version: $ctrdVersion"
    }

    Invoke-Step "Initialize Packer plugins (WS${OSVersion})" {
        Push-Location $script:PackerWindowsDir
        try {
            packer init .
            if ($LASTEXITCODE -ne 0) { throw "packer init failed (exit $LASTEXITCODE)" }
        } finally { Pop-Location }
    }

    Invoke-Step "Run Packer build (Windows Server ${OSVersion} base)" {
        Push-Location $script:PackerWindowsDir
        try {
            $env:PACKER_LOG      = 1
            $env:PACKER_LOG_PATH = Join-Path $script:OutputDir "packer-win${OSVersion}-base.log"

            $k8sVersion = $script:K3sVersion -replace '\+k3s\d+$', ''
            $diskMB     = $script:DiskSizeGB * 1024

            # Use the CPU/RAM from the largest spec for this OS version (base must fit any node)
            $specForOS = $script:WindowsNodeSpecs | Where-Object { $_.OSVersion -eq $OSVersion }
            $maxCPU    = ($specForOS | Measure-Object -Property CPU -Maximum).Maximum
            $maxRAM    = ($specForOS | Measure-Object -Property RAM -Maximum).Maximum

            packer build `
                -var "vm_name=$baseVMName" `
                -var "os_version=$OSVersion" `
                -var "cpu_count=$maxCPU" `
                -var "memory_mb=$maxRAM" `
                -var "disk_size_mb=$diskMB" `
                -var "switch_name=$($script:vSwitchName)" `
                -var "admin_pass=$($script:WinAdminPass)" `
                -var "iso_path=$($cfg.IsoFile)" `
                -var "output_dir=$vhdxDir" `
                -var "k8s_version=$k8sVersion" `
                -var "cluster_dns_ip=$($script:ClusterDnsIp)" `
                -var "cluster_cidr=$($script:ClusterCidr)" `
                -var "service_cidr=$($script:ServiceCidr)" `
                -var "flannel_version=$($script:FlannelVersion)" `
                -var "wins_cni_version=$($script:WinsCniVersion)" `
                -var "containerd_version=$ctrdVersion" `
                .

            if ($LASTEXITCODE -ne 0) {
                throw "packer build exited with code $LASTEXITCODE. See $($env:PACKER_LOG_PATH)"
            }
        } finally { Pop-Location }
    }

    # Import so we can add nested virt, then unregister (keep only VHDX)
    Invoke-Step "Import + configure base VM, then unregister (keep VHDX only)" {
        $vmcx = Get-ChildItem -Path $vhdxDir -Recurse -Filter '*.vmcx' -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($vmcx) {
            Import-VM -Path $vmcx.FullName -Register -ErrorAction SilentlyContinue
        }
        $vm = Get-VM -Name $baseVMName -ErrorAction SilentlyContinue
        if ($vm) {
            if ($vm.State -ne 'Off') { Stop-VM -Name $baseVMName -Force -TurnOff }
            # Enable nested virtualisation on the base (inherited by all differencing children)
            Set-VMProcessor -VMName $baseVMName -ExposeVirtualizationExtensions $true
            Remove-VM -Name $baseVMName -Force
            Write-Success "Base VM unregistered (VHDX kept)"
        }
    }

    # Mark base VHDX read-only
    Invoke-Step "Mark WS${OSVersion} base VHDX read-only" {
        $vhdx = Get-ChildItem -Path $vhdxDir -Recurse -Filter '*.vhdx' | Select-Object -First 1
        Assert-True ($null -ne $vhdx) "No .vhdx found under '$vhdxDir' after Packer build."
        Set-ItemProperty -Path $vhdx.FullName -Name IsReadOnly -Value $true
        Write-Success "Read-only: $($vhdx.FullName)"
    }

    Reset-PhaseComplete $sentinel
    Set-PhaseComplete   $sentinel
    Write-PhaseDone "BASE-W${OSVersion}"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
$versionsNeeded = @(Get-RequiredWindowsVersions)

if ($versionsNeeded.Count -eq 0) {
    Write-Success 'No Windows nodes configured (WindowsNodeSpecs is empty) — skipping Windows base builds.'
    exit 0
}

if ($Force) {
    foreach ($v in $versionsNeeded) { Reset-PhaseComplete "win${v}-base" }
}

foreach ($version in $versionsNeeded) {
    Invoke-WindowsBaseForVersion -OSVersion $version
}
