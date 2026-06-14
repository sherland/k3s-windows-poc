# winrm-setup.ps1 — Run from FirstLogonCommands via floppy (A:\winrm-setup.ps1)
# Enables WinRM for Packer connectivity. Runs as SYSTEM/Administrator at first logon.

$ErrorActionPreference = 'Continue'

# 1. Disable firewall on all profiles (fastest, safe for an isolated Packer network)
netsh advfirewall set allprofiles state off | Out-Null

# 2. Enable PSRemoting (starts WinRM, creates listener, sets auth)
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# 3. Allow unencrypted and Basic auth (Packer winrm_use_ssl=false requires this)
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'

# 4. Ensure WinRM listener covers all IPs (sometimes it binds only to 127.0.0.1)
$listeners = winrm enumerate winrm/config/listener 2>$null
if ($listeners -notmatch 'Transport = HTTP') {
    winrm create winrm/config/listener?Address=*+Transport=HTTP '@{Port="5985"}'
}

# 5. Set WinRM service to auto-start and restart it cleanly
Set-Service -Name WinRM -StartupType Automatic
Restart-Service -Name WinRM -Force

# 6. Disable Windows Defender real-time (speeds up Packer provisioner file copies)
Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue

Write-EventLog -LogName Application -Source 'Application' -EventId 1 `
    -EntryType Information -Message 'Packer WinRM setup complete' -ErrorAction SilentlyContinue
