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
    # Default to latest 1.7.x — kubelet v1.32 requires CRI v1 gRPC API which was removed in containerd v2.x
    $ContainerdVersion = '1.7.32'
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
# Generate config — write a clean v1.7-compatible config.toml directly.
# Do NOT use `containerd config default` which on v1.7 produces a format
# incompatible with what kubelet v1.32 expects.
# ---------------------------------------------------------------------------
$configDir  = "$InstallDir\config"
$configFile = "$configDir\config.toml"
$null = New-Item -ItemType Directory -Force -Path $configDir

Write-Log "03-containerd: Generating containerd config.toml..."
@"
version = 2
root    = "C:\\ProgramData\\containerd\\root"
state   = "C:\\ProgramData\\containerd\\state"

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "mcr.microsoft.com/oss/kubernetes/pause:3.9"
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runhcs-wcow-process"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runhcs-wcow-process]
          runtime_type = "io.containerd.runhcs.v1"
    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir  = "C:\\k\\cni"
      conf_dir = "C:\\k\\cni\\config"
"@ | Set-Content -Path $configFile -Encoding ascii
Write-Log "03-containerd: config.toml written"

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
