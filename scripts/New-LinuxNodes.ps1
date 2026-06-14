# =============================================================================
# scripts/New-LinuxNodes.ps1
# Phase 4 — Create all Linux VMs as differencing disks from the golden base.
#
# Creates:
#   - Control-plane VM (k8s-cp-01)  — started; cloud-init sets hostname + SSH key
#   - Linux worker VMs (k8s-lnx-NN) — started; same identity seed pattern
#
# The k3s roles (server / agent) are configured LATER:
#   - CP:      Bootstrap-ControlPlane.ps1 (Phase 6)
#   - Workers: Join-Nodes.ps1 (Phase 7, via SSH)
#
# Cloud-init seed ISOs use the NoCloud datasource:
#   ISO volume label = CIDATA
#   /meta-data: instance-id + local-hostname
#   /user-data: set hostname, inject SSH key, enable sudo
#
# Sentinel per node: node-{vmname}.done
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

$SeedISODir = Join-Path $script:OutputDir 'seed-isos'

# ---------------------------------------------------------------------------
function New-SshKeyPairIfNeeded {
    if (Test-Path $script:SshKeyPath) { return }
    Write-Step "Generating SSH key pair for node management..."
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $script:SshKeyPath)
    ssh-keygen -t ed25519 -N '' -f $script:SshKeyPath -C 'packer-linux-build' | Out-Null
}

# ---------------------------------------------------------------------------
function Get-NodeUserData {
    param([string]$NodeName)
    <#
        Minimal cloud-config for a cloned node:
        - Set hostname
        - Ensure admin user has the management SSH key
        - Sudo already configured in base image, just carry it forward
    #>
    $pubKey = (Get-Content "$($script:SshKeyPath).pub" -Raw).Trim()
    return @"
#cloud-config
hostname: $NodeName
fqdn: $NodeName
prefer_fqdn_over_hostname: false
manage_etc_hosts: true
users:
  - name: $($script:LinuxAdminUser)
    groups: [adm, sudo, docker]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $pubKey
"@
}

# ---------------------------------------------------------------------------
function New-LinuxNode {
    param([string]$NodeName)

    $nodeSentinel = "node-$NodeName"
    if (-not $Force -and (Test-PhaseComplete $nodeSentinel)) {
        $vm = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
        if ($vm) {
            Write-Success "Node '$NodeName' already created — skipping"
            return
        }
        Reset-PhaseComplete $nodeSentinel  # stale sentinel, re-create
    }

    Write-Step "--- Creating Linux node: $NodeName ---"

    # Create differencing disk + VM
    $parentVhdx = Get-BaseVhdxPath 'linux'
    $childVhdx  = Get-NodeVhdxPath $NodeName

    # Remove stale VM if it exists
    $stale = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
    if ($stale) {
        Write-Warn "Removing stale VM '$NodeName'..."
        if ($stale.State -ne 'Off') { Stop-VM -Name $NodeName -Force -TurnOff }
        Remove-VM -Name $NodeName -Force
    }
    if (Test-Path $childVhdx) {
        Remove-Item $childVhdx -Force
    }

    $memMB = if ($NodeName -eq $script:ControlPlaneVMName) {
        $script:ControlPlaneRAM
    } else {
        $script:LinuxWorkerRAM
    }
    $cpu = if ($NodeName -eq $script:ControlPlaneVMName) {
        $script:ControlPlaneCPU
    } else {
        $script:LinuxWorkerCPU
    }

    New-DifferencingNode -VMName $NodeName -ParentVhdxPath $parentVhdx `
        -ChildVhdxPath $childVhdx -CPU $cpu -MemoryMB $memMB `
        -SwitchName $script:vSwitchName -Generation 2

    # Create cloud-init seed ISO
    $isoPath  = Join-Path $SeedISODir "${NodeName}.iso"
    $userData = Get-NodeUserData -NodeName $NodeName
    New-SeedISO -NodeName $NodeName -IsoPath $isoPath -UserDataContent $userData

    # Attach seed ISO as DVD
    Add-SeedISOToDvd -VMName $NodeName -IsoPath $isoPath

    # Start VM — cloud-init will run on first boot and set hostname + SSH key
    Write-Step "Starting VM '$NodeName'..."
    Start-VM -Name $NodeName
    Write-Success "VM '$NodeName' started"

    Set-PhaseComplete $nodeSentinel
}

# ---------------------------------------------------------------------------
function Wait-ForSSHOnAllLinuxNodes {
    $allNames = Get-AllLinuxNodeNames
    Write-Step "Waiting for SSH on all $($allNames.Count) Linux node(s)..."

    foreach ($name in $allNames) {
        # Inline poll loop — avoids PowerShell scriptblock scope issues with Wait-Until
        $keyPath  = $script:SshKeyPath
        $sshUser  = $script:LinuxAdminUser
        $deadline = (Get-Date).AddSeconds($script:VMBootTimeoutSec)
        $sshOk    = $false
        while ((Get-Date) -lt $deadline) {
            $ip = ($( Get-VM -Name $name -EA SilentlyContinue ).NetworkAdapters |
                   ForEach-Object { $_.IPAddresses } |
                   Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.*' } |
                   Select-Object -First 1)
            if ($ip) {
                $r = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
                         -o ConnectTimeout=5 -i $keyPath "$sshUser@$ip" 'echo ok' 2>&1
                if ($LASTEXITCODE -eq 0 -and ($r | Where-Object { $_ -is [string] }) -contains 'ok') {
                    $sshOk = $true; break
                }
            }
            Write-Step "Waiting for SSH on '$name'..."
            Start-Sleep -Seconds 10
        }
        if (-not $sshOk) { throw "Timeout after $($script:VMBootTimeoutSec)s waiting for SSH on '$name'" }

        $ip = ($( Get-VM -Name $name ).NetworkAdapters |
               ForEach-Object { $_.IPAddresses } |
               Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.*' } |
               Select-Object -First 1)
        Write-Success "SSH ready on '$name' ($ip)"

        # Store CP IP for later phases
        if ($name -eq $script:ControlPlaneVMName) {
            Set-Content -Path (Join-Path $script:OutputDir 'linux-vm-ip.txt') -Value $ip.Trim()
        }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
Write-PhaseHeader '4' 'Create Linux node VMs (differencing disks from golden base)'

New-SshKeyPairIfNeeded
$null = New-Item -ItemType Directory -Force -Path $SeedISODir

$allLinux = Get-AllLinuxNodeNames
foreach ($nodeName in $allLinux) {
    New-LinuxNode -NodeName $nodeName
}

Wait-ForSSHOnAllLinuxNodes

Write-PhaseDone '4'
