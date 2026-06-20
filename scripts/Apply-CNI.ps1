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

            Invoke-Step 'Helm install Calico (tigera-operator)' {
                helm upgrade --install calico projectcalico/tigera-operator `
                    --namespace tigera-operator `
                    --create-namespace `
                    --version $script:CalicoVersion `
                    -f $valuesFile `
                    --wait --timeout 10m
                if ($LASTEXITCODE -ne 0) { throw "helm install calico failed (exit $LASTEXITCODE)" }
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

        default {
            throw "Unknown CNI plugin: '$($script:CNIPlugin)'. Valid values: 'flannel', 'flannel+cilium', 'cilium', 'multus', 'calico', 'none'."
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
