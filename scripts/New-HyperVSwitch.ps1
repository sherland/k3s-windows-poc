# =============================================================================
# scripts/New-HyperVSwitch.ps1
# Phase 1 — Create (or verify) an external Hyper-V vSwitch.
# Idempotent: if the switch already exists and is bound to a physical NIC,
# the phase is skipped.
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
function Resolve-HostNic {
    <#
        Returns the name of the best physical NIC to bind the external switch to.
        Prefers the NIC that currently has a default-gateway route (i.e. the
        "internet-facing" adapter).

        Retries up to ~30 s because after a previous vSwitch removal the host
        routing table briefly disappears while the NIC is rebound, causing a
        spurious "no NIC found" failure on fast re-runs.
    #>
    if ($script:HostNicName -and $script:HostNicName -ne '') {
        $nic = Get-NetAdapter -Name $script:HostNicName -ErrorAction SilentlyContinue
        if (-not $nic) {
            throw "Configured HostNicName '$($script:HostNicName)' not found. " +
                  "Check config/variables.ps1."
        }
        return $nic.Name
    }

    # Helper: one detection attempt — returns NIC name or $null
    $tryDetect = {
        # Strategy 1: NIC carrying the default route
        $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                        Sort-Object RouteMetric | Select-Object -First 1
        if ($defaultRoute) {
            $nic = Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue
            if ($nic -and $nic.Status -eq 'Up' -and $nic.PhysicalMediaType -ne '') {
                return $nic.Name
            }
        }

        # Strategy 2: any Up adapter that is not a Hyper-V virtual NIC
        # (MediaType 802.3 covers wired Ethernet; 'Native 802.11' covers Wi-Fi)
        $nic = Get-NetAdapter -ErrorAction SilentlyContinue |
               Where-Object {
                   $_.Status -eq 'Up' -and
                   $_.HardwareInterface -eq $true -and
                   $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback'
               } |
               Sort-Object LinkSpeed -Descending |
               Select-Object -First 1
        if ($nic) { return $nic.Name }

        return $null
    }

    # Retry loop — the default route can disappear briefly after vSwitch teardown
    $deadline = (Get-Date).AddSeconds(30)
    while ($true) {
        $name = & $tryDetect
        if ($name) { return $name }

        if ((Get-Date) -ge $deadline) { break }
        Write-Step 'NIC auto-detection: routing table not yet stable, retrying in 5 s...'
        Start-Sleep -Seconds 5
    }

    throw 'Could not detect a suitable physical NIC after 30 s. ' +
          'Set $script:HostNicName in config/variables.ps1 and re-run.'
}

# ---------------------------------------------------------------------------
function Test-Phase1Complete {
    if (-not (Test-PhaseComplete 'phase1')) { return $false }

    $sw = Get-VMSwitch -Name $script:vSwitchName -ErrorAction SilentlyContinue
    return ($null -ne $sw -and $sw.SwitchType -eq 'External')
}

# ---------------------------------------------------------------------------
function Assert-Phase1Complete {
    Write-Step 'Verifying Phase 1 (vSwitch)...'

    $sw = Get-VMSwitch -Name $script:vSwitchName -ErrorAction SilentlyContinue
    Assert-True ($null -ne $sw) "vSwitch '$($script:vSwitchName)' does not exist" `
        "Run New-HyperVSwitch.ps1 -Force"

    Assert-True ($sw.SwitchType -eq 'External') `
        "vSwitch '$($script:vSwitchName)' is not External (type: $($sw.SwitchType))" `
        "Delete the switch and re-run New-HyperVSwitch.ps1 -Force"

    Write-Success "Phase 1 OK — switch '$($script:vSwitchName)' is External"
}

# ---------------------------------------------------------------------------
function Invoke-Phase1 {
    Write-PhaseHeader '1' 'Hyper-V External vSwitch'

    $nicName = Resolve-HostNic
    Write-Step "Using NIC: $nicName"

    $existing = Get-VMSwitch -Name $script:vSwitchName -ErrorAction SilentlyContinue

    if ($existing) {
        if ($existing.SwitchType -eq 'External') {
            Write-Success "Switch '$($script:vSwitchName)' already exists as External"
        } else {
            Write-Warn "Switch '$($script:vSwitchName)' exists but is type '$($existing.SwitchType)' — removing and recreating..."
            Remove-VMSwitch -Name $script:vSwitchName -Force
            $existing = $null
        }
    }

    if (-not $existing) {
        Invoke-Step "Create external vSwitch '$($script:vSwitchName)' on NIC '$nicName'" {
            New-VMSwitch -Name $script:vSwitchName `
                         -NetAdapterName $nicName `
                         -AllowManagementOS $true | Out-Null
        }
        # The vSwitch rebinds the physical NIC which briefly disrupts the host network.
        # Wait for DNS to stabilise before subsequent phases attempt internet access.
        Write-Step 'Waiting 20s for host network to stabilise after vSwitch creation...'
        Start-Sleep -Seconds 20
    }

    Assert-Phase1Complete
    Set-PhaseComplete 'phase1'
    Write-PhaseDone '1'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($Force) { Reset-PhaseComplete 'phase1' }

if (Test-Phase1Complete) {
    Write-Success 'Phase 1 already complete — skipping'
} else {
    Invoke-Phase1
}
