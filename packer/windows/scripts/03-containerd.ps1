# =============================================================================
# packer/windows/scripts/03-containerd.ps1
# Install and configure containerd for Windows with Hyper-V isolation.
# Environment variable injected by Packer: CONTAINERD_VERSION
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Msg) Write-Host "[$(Get-Date -f HH:mm:ss)] $Msg" }

$ContainerdVersion = $env:CONTAINERD_VERSION
if (-not $ContainerdVersion -or $ContainerdVersion -eq 'latest') {
    # Default to the 2.3 LTS line (1.7 reached EOL 2026-09-30; 2.2+/2.3+ required by k8s 1.36 kubelet)
    $ContainerdVersion = '2.3.7'
}
Write-Log "03-containerd: Using containerd v$ContainerdVersion"

$InstallDir   = 'C:\containerd'
$BinDir       = "$InstallDir\bin"
$ZipPath      = "$env:TEMP\containerd.zip"
$DownloadUrl  = "https://github.com/containerd/containerd/releases/download/v$ContainerdVersion/containerd-$ContainerdVersion-windows-amd64.tar.gz"

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
if (-not (Test-Path "$BinDir\containerd.exe")) {
    Write-Log "03-containerd: Downloading containerd..."
    $null = New-Item -ItemType Directory -Force -Path $BinDir

    # tar.gz - use curl.exe (built-in since Win10/WS2019) + tar (built-in since Win10 1803)
    $tarPath = "$env:TEMP\containerd.tar.gz"
    curl.exe -fsSL -o $tarPath $DownloadUrl
    if ($LASTEXITCODE -ne 0) { throw "Download failed for $DownloadUrl" }

    Write-Log "03-containerd: Extracting..."
    tar.exe -xzf $tarPath -C $InstallDir 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Extraction failed" }

    Remove-Item $tarPath -Force
} else {
    Write-Log "03-containerd: containerd.exe already present - skipping download"
}

# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------
$currentPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
if ($currentPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable('PATH', "$currentPath;$BinDir", 'Machine')
    $env:PATH = "$env:PATH;$BinDir"
    Write-Log "03-containerd: Added $BinDir to system PATH"
}

# ---------------------------------------------------------------------------
# Generate config - write a v3-schema config.toml directly (containerd 2.x).
# Do NOT use `containerd config default`, which pulls in the full set of
# built-in plugins/defaults rather than the minimal CRI-focused config below.
# ---------------------------------------------------------------------------
$configDir  = "$InstallDir\config"
$configFile = "$configDir\config.toml"
$null = New-Item -ItemType Directory -Force -Path $configDir

Write-Log "03-containerd: Generating containerd config.toml..."
@"
version = 3
root  = 'C:\ProgramData\containerd\root'
state = 'C:\ProgramData\containerd\state'

[plugins.'io.containerd.cri.v1.images'.pinned_images]
  sandbox = 'registry.k8s.io/pause:3.10.2'

[plugins.'io.containerd.cri.v1.runtime'.containerd]
  default_runtime_name = 'runhcs-wcow-process'
  [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runhcs-wcow-process]
    runtime_type = 'io.containerd.runhcs.v1'

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dirs = ['C:\k\cni']
  conf_dir = 'C:\k\cni\config'
"@ | Set-Content -Path $configFile -Encoding ascii
Write-Log "03-containerd: config.toml written"

# containerd silently falls back to its built-in defaults (bin dir under
# "C:\Program Files\containerd\cni\bin") when --config points at a missing or
# unreadable file - a log-only check would not catch a wrong path, so assert
# the dumped effective config instead.
# containerd writes a harmless "config migrated" notice to stderr; under
# $ErrorActionPreference = 'Stop' (Windows PowerShell 5.1, which is what
# Packer's powershell provisioner actually runs), capturing stderr via 2>&1
# promotes that notice to a terminating error regardless of exit code - drop
# to 'Continue' for just this call and check $LASTEXITCODE explicitly instead.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$dumpLines = & "$BinDir\containerd.exe" --config $configFile config dump 2>&1
$dumpExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($dumpExit -ne 0) { throw "containerd config dump failed (exit $dumpExit): $dumpLines" }
$dump = $dumpLines -join "`n"
if ($dump -notmatch 'bin_dirs' -or $dump -notmatch [regex]::Escape('C:\k\cni')) {
    throw "containerd effective config does not have the expected CNI bin_dirs. Dump:`n$dump"
}
if ($dump -notmatch [regex]::Escape('registry.k8s.io/pause:3.10.2')) {
    throw "containerd effective config does not have the expected pinned sandbox image. Dump:`n$dump"
}
Write-Log "03-containerd: config dump verified (bin_dirs + pinned sandbox image)"

# ---------------------------------------------------------------------------
# Install as Windows Service
# ---------------------------------------------------------------------------
$svc = Get-Service -Name containerd -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Log "03-containerd: Registering containerd as a service..."
    & "$BinDir\containerd.exe" --register-service `
        --config "$configFile" `
        --log-file "$InstallDir\containerd.log"
    if ($LASTEXITCODE -ne 0) { throw "containerd --register-service failed" }
}

Set-Service -Name containerd -StartupType Automatic
Start-Service -Name containerd

# Wait up to 30s for containerd to become running
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    $s = (Get-Service containerd -ErrorAction SilentlyContinue).Status
    if ($s -eq 'Running') { break }
    Start-Sleep -Seconds 2
}

$finalState = (Get-Service containerd).Status
if ($finalState -ne 'Running') {
    throw "containerd service failed to start (state: $finalState). Check $InstallDir\containerd.log"
}
Write-Log "03-containerd: containerd service is Running"

# ---------------------------------------------------------------------------
# Verify with ctr
# ---------------------------------------------------------------------------
$ctrPath = "$BinDir\ctr.exe"
if (Test-Path $ctrPath) {
    $ver = & $ctrPath version 2>&1
    Write-Log "03-containerd: ctr version: $ver"
}

Write-Log '03-containerd: Done'
