# =============================================================================
# scripts/Apply-CNI.ps1
# Phase 8 — Apply CNI plugin manifests if CNIPlugin != 'flannel'.
#
# flannel  → no-op (k3s embeds flannel; Windows nodes use flanneld.exe baked
#            into the base image)
# cilium   → helm install cilium/cilium using config/cni/cilium-values.yaml
# none     → no-op (user manages CNI manually)
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

        'cilium' {
            Write-Step "Installing Cilium via Helm..."

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
                    -f $valuesFile `
                    --wait --timeout 10m
                if ($LASTEXITCODE -ne 0) { throw "helm install cilium failed (exit $LASTEXITCODE)" }
            }

            # Verify Cilium pods are running
            Wait-Until -TimeoutSec 300 -PollSec 10 -Description 'Cilium pods Running' -Condition {
                $pods = kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>$null
                $running = @($pods | Where-Object { $_ -match '\bRunning\b' }).Count
                $total   = @($pods).Count
                Write-Step "  Cilium pods: $running/$total Running"
                return ($total -gt 0 -and $running -eq $total)
            }
            Write-Success "Cilium CNI installed and all pods Running"
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
            throw "Unknown CNI plugin: '$($script:CNIPlugin)'. Valid values: 'flannel', 'cilium', 'multus', 'calico', 'none'."
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
