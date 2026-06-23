# =============================================================================
# scripts/Apply-CNI.ps1
# Phase 8 — Apply CNI plugin manifests if CNIPlugin != 'flannel'.
#
# flannel         → no-op (k3s embeds flannel; Windows nodes use flanneld.exe baked
#                   into the base image)
# flannel+cilium  → helm install Cilium in generic-veth chaining mode on top of Flannel
#                   using config/cni/cilium-chained-values.yaml; Windows nodes unaffected
# cilium          → helm install cilium/cilium using config/cni/cilium-values.yaml
# none            → no-op (user manages CNI manually)
#
# Sentinel: cni.done
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

$KubeconfigPath = Join-Path $script:OutputDir 'admin-kubeconfig.yaml'
if (-not (Test-Path $KubeconfigPath)) {
    # Fall back to final kubeconfig if admin one not present
    $KubeconfigPath = Join-Path $script:OutputDir 'kubeconfig.yaml'
}

# ---------------------------------------------------------------------------
function Invoke-ApplyCNI {
    Write-PhaseHeader '8' "Apply CNI plugin: $($script:CNIPlugin)"

    $env:KUBECONFIG = $KubeconfigPath

    switch ($script:CNIPlugin) {
        'flannel' {
            Write-Success "CNI = 'flannel' — k3s embeds flannel for Linux; Windows nodes use flanneld.exe. No action needed."
        }

        'flannel+cilium' {
            Write-Step "Installing Cilium (chaining mode) via Helm — version $($script:CiliumVersion)..."

            $helmCmd = Get-Command helm -ErrorAction SilentlyContinue
            Assert-True ($null -ne $helmCmd) `
                "helm not found on PATH. Install: winget install --id Helm.Helm" `
                "Run: winget install --id Helm.Helm"

            helm repo add cilium https://helm.cilium.io/ 2>&1 | Out-Null
            helm repo update 2>&1 | Out-Null

            $valuesFile = Join-Path $script:RepoRoot 'config\cni\cilium-chained-values.yaml'
            Assert-True (Test-Path $valuesFile) "Cilium chained values file not found at '$valuesFile'"

            Invoke-Step 'Helm install Cilium (chained)' {
                helm upgrade --install cilium cilium/cilium `
                    --namespace kube-system `
                    --version $script:CiliumVersion `
                    -f $valuesFile
                if ($LASTEXITCODE -ne 0) { throw "helm install cilium (chained) failed (exit $LASTEXITCODE)" }
            }

            # Wait for cilium pods on Linux nodes
            Wait-Until -TimeoutSec 300 -PollSec 10 -Description 'Cilium pods Running' -Condition {
                $pods = kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>$null
                $running = @($pods | Where-Object { $_ -match '\bRunning\b' }).Count
                $total   = @($pods).Count
                Write-Step "  Cilium pods: $running/$total Running"
                return ($total -gt 0 -and $running -eq $total)
            }

            # Restart CoreDNS so its pod interface gets Cilium eBPF programs attached
            Invoke-Step 'Restart CoreDNS to pick up Cilium eBPF hooks' {
                kubectl rollout restart deployment coredns -n kube-system 2>&1 | ForEach-Object { Write-Step "  $_" }
                kubectl rollout status deployment coredns -n kube-system --timeout=120s 2>&1 | ForEach-Object { Write-Step "  $_" }
            }

            Write-Success "Cilium (chained) installed — eBPF active on Linux nodes, Windows nodes unaffected"
        }

        'cilium' {
            Write-Step "Installing Cilium via Helm — version $($script:CiliumVersion)..."

            $helmCmd = Get-Command helm -ErrorAction SilentlyContinue
            Assert-True ($null -ne $helmCmd) `
                "helm not found on PATH. Install: winget install --id Helm.Helm" `
                "Run: winget install --id Helm.Helm"

            # Add Cilium Helm repo
            helm repo add cilium https://helm.cilium.io/ 2>&1 | Out-Null
            helm repo update 2>&1 | Out-Null

            $valuesFile = Join-Path $script:RepoRoot 'config\cni\cilium-values.yaml'
            Assert-True (Test-Path $valuesFile) "Cilium values file not found at '$valuesFile'"

            Invoke-Step 'Helm install Cilium' {
                helm upgrade --install cilium cilium/cilium `
                    --namespace kube-system `
                    --version $script:CiliumVersion `
                    -f $valuesFile
                if ($LASTEXITCODE -ne 0) { throw "helm install cilium failed (exit $LASTEXITCODE)" }
            }

            # Wait for Cilium agent pods on all Linux nodes
            Wait-Until -TimeoutSec 300 -PollSec 10 -Description 'Cilium pods Running' -Condition {
                $pods = kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>$null
                $running = @($pods | Where-Object { $_ -match '\bRunning\b' }).Count
                $total   = @($pods).Count
                Write-Step "  Cilium pods: $running/$total Running"
                return ($total -gt 0 -and $running -eq $total)
            }

            # Wait for Hubble relay if deployed (hubble.relay.enabled: true in cilium-values.yaml)
            $null = kubectl get deployment hubble-relay -n kube-system 2>&1
            if ($LASTEXITCODE -eq 0) {
                Wait-Until -TimeoutSec 180 -PollSec 10 -Description 'Hubble relay Ready' -Condition {
                    $dep     = kubectl get deployment hubble-relay -n kube-system -o json 2>&1 | ConvertFrom-Json
                    $ready   = if ($dep.status.PSObject.Properties['readyReplicas']) { [int]$dep.status.readyReplicas } else { 0 }
                    $desired = [int]$dep.spec.replicas
                    Write-Step "  hubble-relay: $ready/$desired Ready"
                    return ($desired -gt 0 -and $ready -eq $desired)
                }
            }

            # Restart CoreDNS so its pod interface gets Cilium eBPF programs attached
            Invoke-Step 'Restart CoreDNS to pick up Cilium eBPF hooks' {
                kubectl rollout restart deployment coredns -n kube-system 2>&1 | ForEach-Object { Write-Step "  $_" }
                kubectl rollout status deployment coredns -n kube-system --timeout=120s 2>&1 | ForEach-Object { Write-Step "  $_" }
            }

            Write-Success "Cilium CNI installed — eBPF active, Hubble relay ready"
        }

        'multus' {
            Write-Step "Deploying Multus CNI $($script:MultusVersion) on top of k3s embedded flannel..."

            # Multus requires Linux nodes only (Windows workers keep flannel)
            $winNodes = @(Get-AllWindowsNodeNames)
            if ($winNodes.Count -gt 0) {
                Write-Warn "Windows nodes detected. Multus is deployed only on Linux nodes; Windows workers retain flannel."
            }

            $manifestPath = Join-Path $script:RepoRoot 'config\cni\multus-daemonset.yaml'
            Assert-True (Test-Path $manifestPath) "Multus manifest not found at '$manifestPath'"

            Invoke-Step 'Apply Multus CRD + RBAC + DaemonSet' {
                kubectl apply -f $manifestPath 2>&1 | ForEach-Object { Write-Step "  $_" }
                if ($LASTEXITCODE -ne 0) { throw "kubectl apply multus failed (exit $LASTEXITCODE)" }
            }

            # Wait for multus DaemonSet to have all desired pods Running
            $null = Wait-Until -TimeoutSec 300 -PollSec 10 -Description 'Multus pods Running' -Condition {
                $dsJson = kubectl get ds kube-multus-ds -n kube-system -o json 2>$null | ConvertFrom-Json
                if (-not $dsJson) { return $false }
                $desired     = [int]$dsJson.status.desiredNumberScheduled
                $numberReady = [int]$dsJson.status.numberReady
                Write-Step "  Multus DaemonSet: $numberReady/$desired Ready"
                return ($desired -gt 0 -and $numberReady -eq $desired)
            }
            Write-Success "Multus $($script:MultusVersion) installed — all pods Ready"

            # Verify the NetworkAttachmentDefinition CRD is registered
            Invoke-Step 'Verify NetworkAttachmentDefinition CRD' {
                $crd = kubectl get crd network-attachment-definitions.k8s.cni.cncf.io 2>$null
                Assert-True ($LASTEXITCODE -eq 0) "NetworkAttachmentDefinition CRD not found after multus deploy"
                Write-Success "NetworkAttachmentDefinition CRD registered"
            }

            # Install containernetworking/plugins (macvlan, ipvlan, etc.) on every Linux node.
            # k3s ships only its own bundled CNI binaries; Multus v4.x silently drops secondary
            # interface attachments when the delegated binary (e.g. macvlan) is absent — no pod
            # Warning is emitted.  Binaries go to /var/lib/rancher/k3s/data/cni/ which is the
            # host path that the Multus DaemonSet mounts at /opt/cni/bin inside its container.
            $allLinuxNodes = Get-AllLinuxNodeNames
            Write-Step "Installing cni-plugins $($script:CniPluginsVersion) on $($allLinuxNodes.Count) Linux node(s)..."

            # Build the install script with LF-only line endings and write it to a temp file.
            # Using WriteAllText+ASCII avoids the CRLF that PowerShell here-strings emit on Windows,
            # which corrupts bash heredoc/script execution via SSH.
            $scriptLines = @(
                'set -e',
                "CNI_VER='$($script:CniPluginsVersion)'",
                "ARCH=`$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')",
                "CNI_BIN_DIR='/var/lib/rancher/k3s/data/cni'",
                'TMP=$(mktemp -d)',
                'curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VER}/cni-plugins-linux-${ARCH}-${CNI_VER}.tgz" -o "${TMP}/cni-plugins.tgz"',
                'sudo tar -xz -C "${CNI_BIN_DIR}" -f "${TMP}/cni-plugins.tgz"',
                'rm -rf "${TMP}"',
                'ls "${CNI_BIN_DIR}/macvlan" > /dev/null',
                'echo "cni-plugins ${CNI_VER} installed OK (macvlan present)"'
            )
            $tmpScript = Join-Path $env:TEMP 'install-cni-plugins.sh'
            [System.IO.File]::WriteAllText(
                $tmpScript,
                ($scriptLines -join "`n") + "`n",
                [System.Text.Encoding]::ASCII
            )

            foreach ($nodeName in $allLinuxNodes) {
                Invoke-Step "Install cni-plugins on '$nodeName'" {
                    $nodeIp = Get-VMIPAddress -VMName $nodeName
                    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null `
                        -i $script:SshKeyPath $tmpScript `
                        "$($script:LinuxAdminUser)@${nodeIp}:/tmp/install-cni-plugins.sh" | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "SCP of cni-plugins install script to '$nodeName' failed" }
                    Invoke-SshCommand -HostIp $nodeIp -User $script:LinuxAdminUser `
                        -KeyPath $script:SshKeyPath -Command 'bash /tmp/install-cni-plugins.sh'
                }
            }
            Remove-Item $tmpScript -ErrorAction SilentlyContinue
            Write-Success "cni-plugins $($script:CniPluginsVersion) installed on all Linux nodes"
        }

        'none' {
            Write-Warn "CNI = 'none' — no CNI plugin applied. Configure CNI manually before scheduling pods."
        }

        'calico' {
            Write-Step "Installing Calico via Helm (tigera-operator $($script:CalicoVersion))..."

            $helmCmd = Get-Command helm -ErrorAction SilentlyContinue
            Assert-True ($null -ne $helmCmd) `
                "helm not found on PATH. Install: winget install --id Helm.Helm" `
                "Run: winget install --id Helm.Helm"

            # Add Tigera Helm repo
            helm repo add projectcalico https://docs.tigera.io/calico/charts 2>&1 | Out-Null
            helm repo update 2>&1 | Out-Null

            $valuesFile = Join-Path $script:RepoRoot 'config\cni\calico-values.yaml'
            Assert-True (Test-Path $valuesFile) "Calico values file not found at '$valuesFile'"

            # --- Step 1: Install the operator only (CRs disabled) ---
            # The tigera-operator chart installs both the operator deployment AND Custom
            # Resources (Installation, APIServer, Goldmane, Whisker) in a single release.
            # Helm validates all resources against the API server schema BEFORE applying
            # them, so it fails with "no matches for kind X" because the CRDs don't exist
            # yet — they are registered by the operator itself on first run.
            #
            # Fix: two-phase install.
            #   Phase 1 — install the operator deployment only (all CRs disabled via --set).
            #              The operator starts and registers the CRDs.
            #   Phase 2 — helm upgrade with the full values file, which creates the CRs now
            #              that the API server knows the kinds.
            Invoke-Step 'Helm install tigera-operator (operator only, CRs disabled)' {
                helm upgrade --install calico projectcalico/tigera-operator `
                    --namespace tigera-operator `
                    --create-namespace `
                    --version $script:CalicoVersion `
                    --set 'installation.enabled=false' `
                    --set 'apiServer.enabled=false' `
                    --set 'goldmane.enabled=false' `
                    --set 'whisker.enabled=false' `
                    --wait --timeout 5m
                if ($LASTEXITCODE -ne 0) { throw "helm install tigera-operator (phase 1) failed (exit $LASTEXITCODE)" }
            }

            # Wait for the operator pod to be Running (it registers the CRDs when it starts)
            # Note: helm --wait above already ensures the deployment is ready. We just need
            # a brief pause so the CRDs are fully propagated to all API server endpoints.
            Wait-Until -TimeoutSec 120 -PollSec 10 -Description 'tigera-operator pod Running' -Condition {
                $pods = kubectl get pods -n tigera-operator -l 'k8s-app=tigera-operator' --no-headers 2>$null
                $running = @($pods | Where-Object { $_ -match '\bRunning\b' }).Count
                Write-Step "  tigera-operator pods Running: $running"
                return ($running -gt 0)
            }
            Write-Step "Waiting 15s for CRDs to fully register in API server..."
            Start-Sleep -Seconds 15

            # --- Step 2: Upgrade with full values (creates CRs now that CRDs are registered) ---
            Invoke-Step 'Helm upgrade Calico (enable CRs — Installation, APIServer, Goldmane, Whisker)' {
                helm upgrade --install calico projectcalico/tigera-operator `
                    --namespace tigera-operator `
                    --version $script:CalicoVersion `
                    -f $valuesFile `
                    --wait --timeout 10m
                if ($LASTEXITCODE -ne 0) { throw "helm upgrade calico (phase 2) failed (exit $LASTEXITCODE)" }
            }

            # Wait for calico-node pods to be Running
            Wait-Until -TimeoutSec 300 -PollSec 10 -Description 'calico-node pods Running' -Condition {
                $pods = kubectl get pods -n calico-system -l k8s-app=calico-node --no-headers 2>$null
                $running = @($pods | Where-Object { $_ -match '\bRunning\b' }).Count
                $total   = @($pods).Count
                Write-Step "  calico-node pods: $running/$total Running"
                return ($total -gt 0 -and $running -eq $total)
            }
            Write-Success "Calico CNI installed and all calico-node pods Running"
        }

        'antrea' {
            Write-Step "Installing Antrea via Helm — version $($script:AntreaVersion)..."

            $helmCmd = Get-Command helm -ErrorAction SilentlyContinue
            Assert-True ($null -ne $helmCmd) `
                "helm not found on PATH. Install: winget install --id Helm.Helm" `
                "Run: winget install --id Helm.Helm"

            # Add Antrea Helm repo
            helm repo add antrea https://charts.antrea.io 2>&1 | Out-Null
            helm repo update 2>&1 | Out-Null

            $valuesFile = Join-Path $script:RepoRoot 'config\cni\antrea-values.yaml'
            Assert-True (Test-Path $valuesFile) "Antrea values file not found at '$valuesFile'"

            # Install Antrea Linux DaemonSet + controller via Helm
            Invoke-Step "Helm install Antrea $($script:AntreaVersion) (Linux nodes)" {
                helm upgrade --install antrea antrea/antrea `
                    --namespace kube-system `
                    --version $script:AntreaVersion `
                    -f $valuesFile
                if ($LASTEXITCODE -ne 0) { throw "helm install antrea failed (exit $LASTEXITCODE)" }
            }

            # Wait for antrea-controller Deployment
            Wait-Until -TimeoutSec 180 -PollSec 10 -Description 'antrea-controller ready' -Condition {
                $raw = kubectl get deployment antrea-controller -n kube-system -o json 2>$null
                if (-not $raw) { return $false }
                $dep     = $raw | ConvertFrom-Json
                $ready   = if ($dep.status.PSObject.Properties['readyReplicas']) { [int]$dep.status.readyReplicas } else { 0 }
                $desired = [int]$dep.spec.replicas
                Write-Step "  antrea-controller: $ready/$desired Ready"
                return ($desired -gt 0 -and $ready -eq $desired)
            }

            # Wait for antrea-agent DaemonSet on Linux nodes
            Wait-Until -TimeoutSec 300 -PollSec 10 -Description 'antrea-agent pods Running' -Condition {
                $raw = kubectl get ds antrea-agent -n kube-system -o json 2>$null
                if (-not $raw) { return $false }
                $ds      = $raw | ConvertFrom-Json
                $desired = [int]$ds.status.desiredNumberScheduled
                $ready   = if ($ds.status.PSObject.Properties['numberReady']) { [int]$ds.status.numberReady } else { 0 }
                Write-Step "  antrea-agent DaemonSet: $ready/$desired Ready"
                return ($desired -gt 0 -and $ready -eq $desired)
            }
            Write-Success "Antrea CNI installed (Linux nodes)"

            # --- Windows nodes: deploy antrea-windows-with-ovs DaemonSet ---
            $winNodes = @(Get-AllWindowsNodeNames)
            if ($winNodes.Count -gt 0) {
                Write-Step "Windows nodes present ($($winNodes.Count)) — applying antrea-windows-with-ovs DaemonSet..."

                $cpIp = (Get-Content (Join-Path $script:OutputDir 'linux-vm-ip.txt') -Raw).Trim()
                Assert-True ($cpIp -ne '') "Could not read CP IP from output/linux-vm-ip.txt"

                $antreaTag    = "v$($script:AntreaVersion)"
                $winManifestUrl = "https://github.com/antrea-io/antrea/releases/download/${antreaTag}/antrea-windows-with-ovs.yml"

                Write-Step "  Downloading $winManifestUrl..."
                $response = Invoke-WebRequest -Uri $winManifestUrl -UseBasicParsing
                # GitHub releases set Content-Type: application/octet-stream → .Content is byte[].
                # Explicitly decode to string; otherwise PowerShell serialises the array as "System.Byte[]".
                $winManifest = if ($response.Content -is [byte[]]) {
                    [System.Text.Encoding]::UTF8.GetString($response.Content)
                } else {
                    [string]$response.Content
                }

                # Patch kubeAPIServerOverride — required for proxyAll mode on Windows.
                # In antrea-windows-with-ovs.yml the field is commented out by default:
                #   #kubeAPIServerOverride: ""
                # The regex must match both the commented-out and any uncommented form
                # and replace with the actual CP address (uncommented).
                $winManifest = $winManifest -replace '#?\s*kubeAPIServerOverride:\s*"[^"]*"', "kubeAPIServerOverride: `"https://${cpIp}:6443`""

                # Patch transportInterface — Hyper-V Gen 1 VMs place the node IP on
                # "Ethernet 2". When antrea-ovs creates the OVS bridge (Transparent HNS
                # network) the IP migrates to "vEthernet (Ethernet 2)". antrea-agent then
                # discovers that virtual adapter as the uplink and rejects it ("not a
                # physical adapter"). Explicitly naming the physical adapter avoids the
                # confusion. We detect the physical adapter via PowerShell Direct on the
                # first Windows VM and use that name for all Windows nodes in this cluster.
                $winAdapterName = 'Ethernet 2'   # safe default for Hyper-V Gen 1 VMs
                try {
                    $winVmName = $winNodes[0]
                    $winPass   = $script:WinAdminPass
                    $winCred   = New-Object PSCredential($script:WinAdminUser, (ConvertTo-SecureString $winPass -AsPlainText -Force))
                    $detectedAdapter = Invoke-Command -VMName $winVmName -Credential $winCred -ScriptBlock {
                        # The physical adapter is the one that has the default route and
                        # is NOT a Loopback, Pseudo, or vEthernet adapter
                        $iface = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                            Sort-Object RouteMetric | Select-Object -First 1).InterfaceAlias
                        if ($iface -match 'vEthernet') {
                            # OVS already created the bridge; get the underlying physical adapter
                            Get-NetAdapter | Where-Object InterfaceDescription -notmatch 'Hyper-V Virtual|Loopback|Pseudo' |
                                Where-Object Status -eq 'Up' | Select-Object -ExpandProperty Name -First 1
                        } else { $iface }
                    } -ErrorAction SilentlyContinue
                    if ($detectedAdapter) { $winAdapterName = $detectedAdapter.Trim() }
                } catch {
                    Write-Step "  WARNING: could not auto-detect Windows adapter name — using default '$winAdapterName'"
                }
                Write-Step "  transportInterface for Windows nodes: '$winAdapterName'"
                # Use (?m) multiline mode so $ anchors to end-of-line, preventing
                # the regex from crossing newlines and consuming the next comment line.
                # IMPORTANT: capture leading whitespace with (\s*) and back-reference it with ${1}.
                # The transportInterface field lives INSIDE a YAML literal block scalar (the
                # antrea-agent.conf ConfigMap data), so its 4-space indentation is structural.
                # Replacing with a zero-indented string terminates the block scalar early, causing
                # everything after it to be parsed as raw YAML — which fails at the OVS script
                # content (line 72 error: "did not find expected key").
                $winManifest = $winManifest -replace '(?m)^(\s*)#?\s*transportInterface:.*$', ('${1}transportInterface: ' + $winAdapterName)

                # Inject a "prepare-network" init container as the FIRST init container.
                # This HostProcess container runs on the host as SYSTEM before antrea-agent
                # starts. It removes stale HNS networks (antrea-hnsnetwork, cbr0, vxlan0)
                # so the node IP is restored to the physical adapter before antrea-agent
                # initializes. Without this, antrea-agent crashes on pod restart because
                # the previous run's Transparent HNS network keeps the IP on vEthernet.
                $prepareNetworkYaml = @"
      - name: prepare-network
        image: antrea/antrea-windows:v$($script:AntreaVersion)
        command: ["powershell", "-Command"]
        args:
          - |
            `$nets = Get-HnsNetwork -ErrorAction SilentlyContinue | Where-Object Name -in @('antrea-hnsnetwork','cbr0','vxlan0')
            if (`$nets) { `$nets | ForEach-Object { Write-Host "prepare-network: removing HNS `$(`$_.Name)"; Remove-HnsNetwork `$_ } }
            Write-Host "prepare-network: HNS cleanup done (`$(`$nets.Count) network(s) removed)"
        securityContext:
          windowsOptions:
            hostProcess: true
            runAsUserName: "NT AUTHORITY\\SYSTEM"
"@
                # Insert the prepare-network init container before the first init container entry.
                # The manifest has '  initContainers:' followed by '  - name: install-cni'.
                # We insert our YAML block right after the 'initContainers:' line.
                # IMPORTANT: use [regex]::Replace with a scriptblock (MatchEvaluator) instead of
                # -replace, because $prepareNetworkYaml contains '$_' (from 'Remove-HnsNetwork $_')
                # and .NET regex replacement syntax treats '$_' as "entire input string" — which
                # would embed the whole manifest recursively and corrupt the YAML.
                $capturedBlock = $prepareNetworkYaml
                $winManifest = [regex]::Replace($winManifest, '(?m)^(\s+initContainers:\s*)$', {
                    param($m); $m.Groups[1].Value + "`n" + $capturedBlock
                })

                # Inject a "fix-cni-config" init container AFTER install-ovs-driver (before nodeSelector).
                # Two problems to fix here:
                # 1. containerd bin_dir = C:\k\cni, but install-cni puts antrea.exe in C:\opt\cni\bin\.
                #    Copy antrea.exe to C:\k\cni\ so containerd can locate the plugin.
                # 2. containerd conf_dir = C:\k\cni\config, but install-cni writes the conflist to
                #    C:\etc\cni\net.d\. Copy without BOM (containerd rejects BOM-prefixed JSON) and
                #    remove the stale Flannel config that would otherwise take precedence.
                $fixCniYaml = @"
      - name: fix-cni-config
        image: antrea/antrea-windows:v$($script:AntreaVersion)
        command: ["powershell", "-Command"]
        args:
          - |
            `$src = 'C:\etc\cni\net.d\10-antrea.conflist'
            `$dst = 'C:\k\cni\config\10-antrea.conflist'
            Remove-Item 'C:\k\cni\config\10-flannel.conflist' -Force -ErrorAction SilentlyContinue
            `$null = New-Item -ItemType Directory -Force -Path 'C:\k\cni\config'
            if (Test-Path `$src) {
              `$bytes = [System.IO.File]::ReadAllBytes(`$src)
              if (`$bytes.Length -ge 3 -and `$bytes[0] -eq 0xEF -and `$bytes[1] -eq 0xBB -and `$bytes[2] -eq 0xBF) { `$bytes = `$bytes[3..(`$bytes.Length-1)] }
              [System.IO.File]::WriteAllBytes(`$dst, `$bytes)
              Write-Host "fix-cni-config: conflist written to `$dst (no BOM)"
            } else { Write-Host "fix-cni-config: WARNING source `$src not found" }
            Copy-Item 'C:\opt\cni\bin\antrea.exe' 'C:\k\cni\antrea.exe' -Force -ErrorAction SilentlyContinue
            Write-Host "fix-cni-config: antrea.exe copied to C:\k\cni\"
            Restart-Service containerd -ErrorAction SilentlyContinue
        securityContext:
          windowsOptions:
            hostProcess: true
            runAsUserName: "NT AUTHORITY\\SYSTEM"
"@
                # Insert fix-cni-config as the LAST initContainer, just before nodeSelector:.
                # In antrea-windows-with-ovs.yml the spec order is: containers: → initContainers:
                # → nodeSelector: (not the typical initContainers-first order).  Injecting before
                # nodeSelector: places fix-cni-config AFTER install-cni and install-ovs-driver,
                # which is required because fix-cni-config reads the config that install-cni writes.
                # Injecting before containers: (as attempted previously) placed a sequence item
                # inside a mapping context, which is invalid YAML (line 72 error).
                $capturedFix = $fixCniYaml
                $winManifest = [regex]::Replace($winManifest, '(?m)^(\s+nodeSelector:\s*)$', {
                    param($m); $capturedFix + "`n" + $m.Groups[1].Value
                })

                # Pipe via stdin to avoid temp-file BOM issues ([System.Text.Encoding]::UTF8
                # in .NET includes a BOM which kubectl's YAML parser rejects).
                Invoke-Step 'Apply antrea-windows-with-ovs DaemonSet (patched)' {
                    $winManifest | kubectl apply -f -
                    if ($LASTEXITCODE -ne 0) { throw "kubectl apply antrea-windows-with-ovs failed (exit $LASTEXITCODE)" }
                }
                # NOTE: We do NOT wait for antrea-agent-windows to reach Running here.
                # The Windows node has not joined the cluster yet — that happens in Phase 7
                # (Join-Nodes). The wait is performed there, after the node is registered.
                Write-Success "Antrea Windows DaemonSet applied — pod will start after Windows node joins (Phase 7)"
            }
            Write-Success "Antrea CNI fully installed (OVS unified data plane)"
        }

        default {
            throw "Unknown CNI plugin: '$($script:CNIPlugin)'. Valid values: 'flannel', 'flannel+cilium', 'cilium', 'multus', 'calico', 'antrea', 'none'."
        }
    }

    Set-PhaseComplete 'cni'
    Write-PhaseDone '8'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($Force) { Reset-PhaseComplete 'cni' }

if (Test-PhaseComplete 'cni') {
    Write-Success 'CNI phase already complete — skipping'
} else {
    Invoke-ApplyCNI
}
