# =============================================================================
# packer/windows/scripts/01-base.ps1
# Base configuration for Windows Server — runs early in Packer provisioning.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Msg) Write-Host "[$(Get-Date -f HH:mm:ss)] $Msg" }

Write-Log '01-base: Starting base configuration'

# ---------------------------------------------------------------------------
# Execution policy
# ---------------------------------------------------------------------------
# Policy may already be Bypass (set by autounattend); a SecurityException is thrown
# when it's already overridden at a higher scope — that's fine, ignore it.
try {
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force
} catch [System.Security.SecurityException] {
    # Already Bypass/Unrestricted from a higher scope — acceptable
}
Write-Log "01-base: ExecutionPolicy is now: $(Get-ExecutionPolicy -Scope LocalMachine)"

# ---------------------------------------------------------------------------
# Disable Windows Firewall for provisioning
# (will be re-enabled selectively by 04-k3s-agent.ps1)
# ---------------------------------------------------------------------------
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Write-Log '01-base: Firewall disabled for provisioning'

# ---------------------------------------------------------------------------
# Disable IPv6 Teredo / 6to4 (can interfere with k3s networking)
# ---------------------------------------------------------------------------
netsh interface teredo set state disabled | Out-Null
netsh interface 6to4 set state disabled   | Out-Null

# ---------------------------------------------------------------------------
# Disable Windows Update automatic restart during provisioning
# ---------------------------------------------------------------------------
reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
    /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f | Out-Null

# ---------------------------------------------------------------------------
# WinRM hardening for Packer (Packer already configured it in autounattend,
# this ensures it survives any policy reset)
# ---------------------------------------------------------------------------
winrm quickconfig -q 2>&1 | Out-Null
winrm set winrm/config/service '@{AllowUnencrypted="true"}' 2>&1 | Out-Null
winrm set winrm/config/service/auth '@{Basic="true"}' 2>&1 | Out-Null
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}' 2>&1 | Out-Null
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

Write-Log '01-base: WinRM configured'

# ---------------------------------------------------------------------------
# Disable auto-logon countdown (avoids interfering with later reboots)
# ---------------------------------------------------------------------------
reg add 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
    /v AutoLogonCount /t REG_DWORD /d 0 /f | Out-Null

Write-Log '01-base: Done'
