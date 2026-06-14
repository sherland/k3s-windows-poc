# =============================================================================
# scripts/Install-Prerequisites.ps1
# Phase 0 — Ensure all host-side tooling is present.
# Idempotent: safe to run multiple times.
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force   # re-run even if sentinel says complete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Helpers.ps1"
. "$PSScriptRoot\..\config\variables.ps1"

# ---------------------------------------------------------------------------
function Test-Phase0Complete {
    if (-not (Test-PhaseComplete 'phase0')) { return $false }

    # Double-check binaries are still reachable
    $allOk = (Get-Command packer   -ErrorAction SilentlyContinue) -and
             (Get-Command kubectl  -ErrorAction SilentlyContinue) -and
             (Get-Command ssh      -ErrorAction SilentlyContinue)

    # Hyper-V feature must be enabled
    return ($allOk -and (Test-HyperVEnabled))
}

# ---------------------------------------------------------------------------
function Test-HyperVEnabled {
    # vmms = Hyper-V Virtual Machine Management service — its presence means HV is installed
    $svc = Get-Service -Name 'vmms' -ErrorAction SilentlyContinue
    if ($null -ne $svc) { return $true }
    # Fallback: DISM.exe command line (avoids the broken PS DISM COM object)
    $out = & dism.exe /Online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1
    return ($out | Where-Object { $_ -match 'State\s*:\s*Enabled' }).Count -gt 0
}

function Enable-HyperV {
    if (Test-HyperVEnabled) {
        Write-Success 'Hyper-V already enabled'
        return
    }

    Write-Step 'Enabling Hyper-V (requires reboot)...'

    # Register this script to resume Main.ps1 after reboot via Run-Once
    $mainScript = Join-Path $PSScriptRoot 'Main.ps1'
    if (Test-Path $mainScript) {
        $regPath  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        $cmd      = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$mainScript`""
        Set-ItemProperty -Path $regPath -Name 'K8sHyperVResume' -Value $cmd
        Write-Step 'Registered Run-Once entry to resume Main.ps1 after reboot'
    }

    $dismResult = & dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V-All /All /NoRestart 2>&1
    if ($LASTEXITCODE -notin @(0, 3010)) {
        throw "DISM failed to enable Hyper-V (exit $LASTEXITCODE): $dismResult"
    }

    Write-Warn 'Hyper-V requires a reboot. Rebooting in 10 seconds...'
    Start-Sleep -Seconds 10
    Restart-Computer -Force
    # Script execution stops here; RunOnce will resume it.
}

# ---------------------------------------------------------------------------
function Install-OpenSSHClient {
    # Prefer binary detection — avoids the broken DISM COM object on this host
    if (Get-Command ssh -ErrorAction SilentlyContinue) {
        Write-Success 'OpenSSH client already installed'
        return
    }
    Write-Step 'Installing OpenSSH client (Windows optional feature)...'
    # Try DISM.exe directly; fall back gracefully if it fails
    $result = & dism.exe /Online /Add-Capability /CapabilityName:OpenSSH.Client~~~~0.0.1.0 2>&1
    if ($LASTEXITCODE -notin @(0, 3010)) {
        # Try winget as second fallback
        Write-Warn "DISM returned $LASTEXITCODE — trying winget fallback..."
        & winget install --id Microsoft.OpenSSH.Beta --source winget --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    }
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw 'OpenSSH client installation failed — ssh.exe not found on PATH after install attempt.'
    }
    Write-Success 'OpenSSH client installed'
}

# ---------------------------------------------------------------------------
function Assert-Phase0Complete {
    Write-Step 'Verifying Phase 0...'

    $missing = @()
    foreach ($bin in @('packer', 'kubectl', 'ssh')) {
        if (-not (Get-Command $bin -ErrorAction SilentlyContinue)) {
            $missing += $bin
        }
    }
    if ($missing.Count -gt 0) {
        throw "Phase 0 verification failed — missing binaries: $($missing -join ', '). " +
              "Check that winget installs completed and PATH was refreshed."
    }

    $pv = (packer version 2>&1) | Select-String 'Packer'
    Assert-True ($null -ne $pv) 'packer --version returned unexpected output'

    $kv = (kubectl version --client --output=yaml 2>&1) | Select-String 'gitVersion'
    Assert-True ($null -ne $kv) 'kubectl version returned unexpected output'

    Assert-True (Test-HyperVEnabled) 'Hyper-V is not enabled' `
        'Run: dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V-All /All'

    Write-Success 'Phase 0 verification passed'
}

# ---------------------------------------------------------------------------
function Invoke-Phase0 {
    Write-PhaseHeader '0' 'Host Prerequisites'

    Assert-DiskSpace -Path 'C:\' -MinimumGB 40

    # --- Hyper-V ---
    Invoke-Step 'Enable Hyper-V' { Enable-HyperV }

    # --- Winget availability ---
    Invoke-Step 'Verify winget' {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw 'winget is not available. Install the App Installer from the Microsoft Store ' +
                  '(ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1) and re-run.'
        }
        Write-Success "winget found: $(winget --version)"
    }

    # --- Packer ---
    Invoke-Step 'Install Packer' {
        Install-WingetPackage -Id $script:PackerWingetId -DisplayName 'Packer' -BinaryName 'packer'
    }

    # --- kubectl ---
    Invoke-Step 'Install kubectl' {
        Install-WingetPackage -Id $script:KubectlWingetId -DisplayName 'kubectl' -BinaryName 'kubectl'
    }

    # --- OpenSSH client ---
    Invoke-Step 'Install OpenSSH client' { Install-OpenSSHClient }

    Assert-Phase0Complete
    Set-PhaseComplete 'phase0'
    Write-PhaseDone '0'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($Force) { Reset-PhaseComplete 'phase0' }

if (Test-Phase0Complete) {
    Write-Success 'Phase 0 already complete — skipping'
} else {
    Invoke-Phase0
}
