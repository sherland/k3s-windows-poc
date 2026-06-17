# Plan: Scenario E — Flannel + Chained Cilium (Linux eBPF + Windows Workers)

## Goal

Add a fifth scenario that runs Cilium in **CNI chaining mode** on top of k3s's embedded
Flannel. Unlike Scenarios C and D (which replace Flannel entirely and are Linux-only), this
scenario:

- Keeps Flannel running so **Windows workers remain compatible** (same as Scenario A).
- Layers Cilium's eBPF engine on top of Flannel on **Linux nodes only**, gaining network
  policy enforcement and Hubble observability without sacrificing cross-platform support.
- Does **not** require `--flannel-backend=none` on the control plane.

This fills the gap in the scenario matrix:

| Scenario | CNI | Linux workers | Windows workers | Cilium eBPF |
|----------|-----|:---:|:---:|:---:|
| A | Flannel (embedded) | ✓ | ✓ | — |
| B | Multus on Flannel | ✓ | — | — |
| C | Cilium (replaces Flannel) | ✓ | — | ✓ |
| D | Calico (replaces Flannel) | ✓ | — | — |
| **E** | **Flannel + chained Cilium** | **✓** | **✓** | **✓** |

---

## How CNI Chaining Works Here

In normal Cilium mode (Scenario C), Cilium **replaces** Flannel: k3s is told
`--flannel-backend=none` and Cilium owns the entire packet path. In chaining mode:

1. k3s starts normally and writes
   `/var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist`.
2. Cilium (via `cni.chainingMode: generic-veth`) appends a `cilium-cni` entry to the
   `plugins` array of that conflist at startup.
3. When a pod is created on a Linux node, Flannel allocates the `veth` pair and sets up
   the bridge. Cilium immediately attaches eBPF programs to the pod-side veth for
   policy enforcement and Hubble flow recording.
4. Flannel continues to own IPAM and routing — Cilium does **not** re-assign IPs.
5. Windows nodes never see the chained conflist; they keep using their own
   `flanneld.exe` stack unchanged.

---

## Changes Required

### 1. `config/variables.ps1` — New CNI value

Add `'flannel+cilium'` to the `$script:CNIPlugin` comment and use it for this scenario:

```powershell
$script:CNIPlugin = 'flannel+cilium'   # 'flannel' | 'flannel+cilium' | 'cilium' | 'multus' | 'calico'
```

`$script:CiliumVersion` is already present and will be reused for the Helm install.

---

### 2. New Helm values — `config/cni/cilium-chained-values.yaml`

Create this file (distinct from `config/cni/cilium-values.yaml` which is used by Scenario C):

```yaml
# Cilium Helm values — CNI chaining mode on top of k3s embedded Flannel.
# Used by Apply-CNI.ps1 when CNIPlugin = 'flannel+cilium'.
#
# Flannel continues to own IPAM and routing; Cilium attaches eBPF programs
# on Linux nodes only. Windows nodes are unaffected.

# Chain onto k3s flannel (conflist "name" field = "cbr0")
cni:
  chainingMode: generic-veth
  chainingTarget: cbr0      # must match the "name" field in 10-flannel.conflist
  exclusive: false
  # k3s writes its CNI conf to a non-standard path — must match or Cilium won't find it
  confFileMountPath: /var/lib/rancher/k3s/agent/etc/cni/net.d
  binPath: /opt/cni/bin     # k3s containerd scans this for CNI plugin binaries

# Do not replace kube-proxy; k3s embeds its own proxy
kubeProxyReplacement: false

# Let Flannel own routing end-to-end
routingMode: native
enableIPv4Masquerade: false

# Pin all Cilium infrastructure to Linux nodes
# (Windows workers keep Flannel-only networking)
nodeSelector:
  kubernetes.io/os: linux

operator:
  replicas: 1               # sufficient for a small PoC
  nodeSelector:
    kubernetes.io/os: linux

# Hubble observability — the primary value-add of this scenario
hubble:
  enabled: true
  relay:
    enabled: true
    nodeSelector:
      kubernetes.io/os: linux
  ui:
    enabled: true
    nodeSelector:
      kubernetes.io/os: linux

# Disable XDP acceleration; Hyper-V vNICs do not support native XDP
nodePort:
  acceleration: disabled

# Disable host services DSR (incompatible with Hyper-V)
hostServices:
  enabled: false

prometheus:
  enabled: false

# Match k3s pod CIDR from config/variables.ps1
ipam:
  mode: kubernetes
```

> **Verify `chainingTarget`:** After bootstrapping k3s on `k8s-cp-01`, confirm the name
> field in the flannel conflist before running Phase 8:
> ```powershell
> $cpIp = (Get-Content 'output\linux-vm-ip.txt').Trim()
> ssh -i output\linux-build-key k8sadmin@$cpIp `
>   "sudo cat /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist"
> ```
> Look for the `"name"` field at the top of the JSON. It should be `cbr0`. If it differs,
> update `cni.chainingTarget` in `config/cni/cilium-chained-values.yaml` before running
> Phase 8.

---

### 3. `scripts/Apply-CNI.ps1` — New `'flannel+cilium'` case

Add a new `switch` branch alongside the existing `'cilium'` case. The logic is almost
identical except it uses `cilium-chained-values.yaml` and does **not** wait for
`--flannel-backend=none` nodes to become Ready (they already are):

```powershell
'flannel+cilium' {
    Write-Step "Installing Cilium (chaining mode) via Helm — version $($script:CiliumVersion)..."

    $helmCmd = Get-Command helm -ErrorAction SilentlyContinue
    Assert-True ($null -ne $helmCmd) `
        "helm not found on PATH. Install: winget install --id Helm.Helm"

    helm repo add cilium https://helm.cilium.io/ 2>&1 | Out-Null
    helm repo update 2>&1 | Out-Null

    $valuesFile = Join-Path $script:RepoRoot 'config\cni\cilium-chained-values.yaml'
    Assert-True (Test-Path $valuesFile) "Cilium chained values file not found at '$valuesFile'"

    Invoke-Step 'Helm install Cilium (chained)' {
        helm upgrade --install cilium cilium/cilium `
            --namespace kube-system `
            --version $script:CiliumVersion `
            -f $valuesFile `
            --wait --timeout 10m
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
```

---

### 4. `scripts/Bootstrap-ControlPlane.ps1` — No change needed

The existing line already handles this correctly:

```powershell
$flannelBackend = if ($script:CNIPlugin -in @('cilium', 'calico')) { 'none' } else { $script:FlannelBackend }
```

`'flannel+cilium'` is **not** in the `@('cilium', 'calico')` list, so the control plane
starts k3s with `--flannel-backend=host-gw` as normal. Flannel runs from the start.

---

### 5. `scripts/Main.ps1` — No change needed

The pre-join CNI logic only applies to `cilium` and `calico`:

```powershell
if ($script:CNIPlugin -in @('cilium', 'calico') -and $PhaseNum -eq 7) {
    & "$ScriptDir\Apply-CNI.ps1" -Force:$Forced  # runs BEFORE Join-Nodes
}
```

For `'flannel+cilium'`, Flannel keeps all nodes `Ready` after bootstrap, so the normal
phase order applies: **Phase 7 (Join-Nodes) → Phase 8 (Apply-CNI)**. No pre-join
ordering change is required.

---

### 6. New `Run-ScenarioE.ps1`

Create at the repo root, following the pattern of `Run-ScenarioD.ps1`:

```powershell
# =============================================================================
# Run-ScenarioE.ps1
# Test Case E: 1 control-plane + 2 Linux workers + 1 Windows node (WS2022)
#              CNI: Flannel (k3s embedded, host-gw) + chained Cilium (Linux only)
#
# k3s starts with Flannel enabled (--flannel-backend=host-gw). After all nodes
# join, Cilium is installed in generic-veth chaining mode using
# config/cni/cilium-chained-values.yaml. Hubble UI is enabled.
# Windows workers join normally via Flannel; Cilium is scoped to Linux nodes.
#
# USAGE (elevated shell):
#   .\Run-ScenarioE.ps1
#   .\Run-ScenarioE.ps1 -NoExtraWorker        # use only 1 Linux worker (skip k8s-lnx-02)
#   .\Run-ScenarioE.ps1 -DeleteGoldenImages   # also rebuild Packer base images from scratch
#   .\Run-ScenarioE.ps1 -SkipCleanup          # skip teardown (e.g. re-run after A passed)
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$SkipCleanup,
    [switch]$DeleteGoldenImages,
    [switch]$NoExtraWorker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot

function Write-Banner([string]$msg) {
    $bar = '=' * 72
    Write-Host "`n$bar" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "$bar`n" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 1. Patch config/variables.ps1 for Scenario E
# ---------------------------------------------------------------------------
$workerCount = if ($NoExtraWorker) { 1 } else { 2 }
$workerLabel = if ($NoExtraWorker) { '1 Linux worker' } else { '2 Linux workers (lnx-01: 4 GB, lnx-02: 2 GB)' }
Write-Banner "SCENARIO E — Flannel + Chained Cilium + CP + $workerLabel + 1 Windows node (WS2022)"

$configPath = Join-Path $ScriptRoot 'config\variables.ps1'
$cfg = Get-Content $configPath -Raw

# Set CNI = flannel+cilium
$cfg = $cfg -replace `
    "\`$script:CNIPlugin\s*=\s*'[^']*'([^\n]*)", `
    "`$script:CNIPlugin      = 'flannel+cilium'    # 'flannel' (embedded, default) | 'flannel+cilium' | 'cilium' | 'multus' | 'calico'"

# Set LinuxWorkerCount
$cfg = $cfg -replace `
    "\`$script:LinuxWorkerCount\s*=\s*\d+([^\n]*)", `
    "`$script:LinuxWorkerCount     = $workerCount             # 0 = control-plane only"

# Set WindowsNodeSpecs = 1x WS2022
$cfg = $cfg -replace `
    '(?s)\$script:WindowsNodeSpecs\s*=\s*@\([^)]*\)[^\r\n]*', `
    "`$script:WindowsNodeSpecs    = @(`n    @{ Count = 1; OSVersion = '2022'; CPU = 4; RAM = 7168 }`n)"

Set-Content $configPath $cfg -Encoding UTF8
Write-Host "[OK] config/variables.ps1 → CNI=flannel+cilium, LinuxWorkerCount=$workerCount, WindowsNodeSpecs=1×WS2022" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Teardown
# ---------------------------------------------------------------------------
if (-not $SkipCleanup) {
    Write-Banner "TEARDOWN (preserving packer_cache and ISOs)"
    $removeArgs = @('-VMs', '-OutputFiles', '-Force')
    if (-not $DeleteGoldenImages) { $removeArgs += '-KeepBaseImages' }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$ScriptRoot\scripts\Remove-Cluster.ps1" @removeArgs
    if ($LASTEXITCODE -ne 0) { throw "Remove-Cluster.ps1 failed (exit $LASTEXITCODE)" }
    Write-Host "[OK] Cluster removed." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 3. Run all phases 0-10
# ---------------------------------------------------------------------------
Write-Banner "RUNNING ALL PHASES (0 → 10)"
& pwsh -NoProfile -ExecutionPolicy Bypass -File "$ScriptRoot\scripts\Main.ps1" 2>&1 |
    ForEach-Object { Write-Host $_ }

$exitCode = $LASTEXITCODE
Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "SCENARIO E COMPLETE — all phases passed." -ForegroundColor Green
} else {
    Write-Host "SCENARIO E FAILED (exit $exitCode). Check output above." -ForegroundColor Red
    exit $exitCode
}
```

---

## Phase Ordering for Scenario E

| # | Script | Notes for `flannel+cilium` |
|---|--------|---------------------------|
| 0 | `Install-Prerequisites.ps1` | Same as all scenarios. Helm must be on PATH. |
| 1 | `New-HyperVSwitch.ps1` | No change. |
| 2 | `Build-LinuxBase.ps1` | No change. |
| 3 | `Build-WindowsBase.ps1` | Required — Windows worker joins. |
| 4 | `New-LinuxNodes.ps1` | No change. |
| 5 | `New-WindowsNodes.ps1` | Required — creates `k8s-win-01`. |
| 6 | `Bootstrap-ControlPlane.ps1` | k3s starts with `--flannel-backend=host-gw`. **Not** `none`. |
| 7 | `Join-Nodes.ps1` | All nodes join and become `Ready` immediately (Flannel is already up). |
| **8** | **`Apply-CNI.ps1`** | **Installs Cilium in chaining mode AFTER all nodes are Ready.** Restarts CoreDNS. |
| 9 | `Export-KubeConfig.ps1` | No change. |
| 10 | `Verify-Cluster.ps1` | Existing checks pass; additional Cilium checks below. |

This is the **same phase order as Scenario A/B** (join first, CNI second). It differs from
Scenarios C and D where `Apply-CNI.ps1` must run before `Join-Nodes.ps1`.

---

## Verification

### Confirm CNI chaining is active on a Linux node

```powershell
$cpIp = (Get-Content 'output\linux-vm-ip.txt').Trim()
ssh -i output\linux-build-key k8sadmin@$cpIp `
  "sudo cat /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist"
```

The `plugins` array in the output should contain **two** entries: `flannel` and `cilium-cni`.

### Confirm Cilium is chained (not owning routing)

```powershell
$env:KUBECONFIG = 'output\admin-kubeconfig.yaml'

kubectl get pods -n kube-system -l k8s-app=cilium -o wide
# All Cilium pods should be on Linux nodes only (k8s-cp-01, k8s-lnx-01, k8s-lnx-02).
# k8s-win-01 should have NO Cilium pod.

kubectl exec -n kube-system ds/cilium -- cilium status
# Should show: "KubeProxyReplacement: Disabled"
# Should show: "chaining-mode: generic-veth"
```

### Access Hubble UI

```powershell
$env:KUBECONFIG = 'output\admin-kubeconfig.yaml'
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# Open http://localhost:12000 in a browser
```

### Cross-platform pod-to-pod test (Linux → Windows)

Deploy a Linux test pod and a Windows test pod, then confirm connectivity flows appear in
Hubble for the Linux-side traffic:

```powershell
$env:KUBECONFIG = 'output\admin-kubeconfig.yaml'

# Deploy Linux debug pod
kubectl run test-linux --image=busybox --restart=Never --command -- sleep 3600 `
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}'

# Deploy Windows test pod
kubectl run test-win --image=mcr.microsoft.com/windows/nanoserver:ltsc2022 `
  --restart=Never --command -- cmd /c "ping -t 127.0.0.1" `
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/os":"windows"}}}'

# Get Windows pod IP and ping from Linux
$winIP = kubectl get pod test-win -o jsonpath='{.status.podIP}'
kubectl exec test-linux -- ping -c 3 $winIP
```

The ping from `test-linux` (Linux node) will appear as an observed flow in Hubble UI.
Traffic originating from `test-win` on `k8s-win-01` will not appear — Windows nodes
bypass Cilium entirely and route directly via Flannel.

---

## Topology Diagram

```
Windows 11 Host (Hyper-V)
│
├── k8s-cp-01     Ubuntu 24.04 — k3s server
│                 flannel (host-gw) + chained cilium-cni
│
├── k8s-lnx-01    Ubuntu 24.04 — k3s agent
│                 flannel bridge (cbr0) + Cilium eBPF programs on pod veth
│                 → Hubble observes all pod flows here
│
├── k8s-lnx-02    Ubuntu 24.04 — k3s agent  (if LinuxWorkerCount = 2)
│                 same as lnx-01
│
└── k8s-win-01    WS2022 — upstream kubelet
                  flanneld.exe + HCN / win-bridge
                  → NO Cilium; pure Flannel data path

External vSwitch: k8s-external  (all VMs + host on same L2)
Pod CIDR:     10.42.0.0/16  (each node gets a /24 slice, assigned by k3s)
Service CIDR: 10.43.0.0/16
CoreDNS:      10.43.0.10
```

---

## Known Limitations

- **Layer 7 policies and transparent encryption** (WireGuard/IPsec) are not supported in
  `generic-veth` chaining mode.
- **Cilium DSR and XDP acceleration** are disabled — Hyper-V vNICs do not expose native XDP.
- **Windows nodes have zero Cilium coverage**: flows from Windows pods are invisible to
  Hubble. Only flows that pass through a Linux-node pod interface are observed.
- **`chainingTarget: cbr0`** must match the `"name"` field in k3s's generated
  `10-flannel.conflist`. If a future k3s release changes that name, update
  `config/cni/cilium-chained-values.yaml` and re-run Phase 8 with `-Force`.
- `cni.exclusive: false` is required; without it Cilium removes the Flannel conflist
  and breaks Windows routing.