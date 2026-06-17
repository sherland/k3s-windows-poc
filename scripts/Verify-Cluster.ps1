# =============================================================================
# scripts/Verify-Cluster.ps1
# Phase 10 — End-to-end cluster verification.
#
# Checks performed:
#   1.  All expected nodes present and Ready
#   2.  No CrashLoopBackOff pods in kube-system
#   3.  CoreDNS pods Running
#   4.  CNI-specific health (multus DaemonSet, NAD CRD)
#   5.  Deploy a test DaemonSet (alpine, linux nodeSelector)
#   6.  Wait for all test pods to be Running
#   7.  Cross-node pod-to-pod ICMP ping (verifies overlay/route connectivity)
#   8.  Cross-node pod-to-pod HTTP curl (busybox httpd on port 8080)
#   9.  DNS resolution inside pods (nslookup kubernetes.default.svc.cluster.local)
#  10.  ClusterIP service reachability (curl to service IP)
#  11.  Hubble flow observability (cilium + flannel+cilium only): relay/UI ready, flows captured
#  12.  Windows node check (if any): kubelet Running, node labeled, pause pod schedules
#  13.  Clean up test namespace
#  14.  Print pass/fail summary with timing
#
# Sentinel: verify.done
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    # Skip deploying pods (just check node/system health)
    [switch]$HealthOnly,
    # Skip cleanup so you can inspect test pods after the run
    [switch]$SkipCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Helpers.ps1"
. "$PSScriptRoot\..\config\variables.ps1"

$KubeconfigPath = Join-Path $script:OutputDir 'kubeconfig.yaml'
$TestNamespace  = 'kube-verify'
$DaemonSetName  = 'verify-ping'
$ServiceName    = 'verify-svc'

$script:PassCount = 0
$script:FailCount = 0
$script:Results   = [System.Collections.Generic.List[string]]::new()

# ---------------------------------------------------------------------------
function Record-Result {
    param([bool]$Pass, [string]$Label, [string]$Detail = '')
    if ($Pass) {
        $script:PassCount++
        $script:Results.Add("  PASS  $Label$(if ($Detail) { " — $Detail" } else { '' })")
        Write-Host "  [PASS] $Label$(if ($Detail) { " — $Detail" } else { '' })" -ForegroundColor Green
    } else {
        $script:FailCount++
        $script:Results.Add("  FAIL  $Label$(if ($Detail) { " — $Detail" } else { '' })")
        Write-Host "  [FAIL] $Label$(if ($Detail) { " — $Detail" } else { '' })" -ForegroundColor Red
    }
}

function Invoke-Kubectl {
    param([string[]]$KArgs)
    $env:KUBECONFIG = $KubeconfigPath
    $result = & kubectl $KArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($KArgs -join ' ') failed (exit $LASTEXITCODE): $result"
    }
    return $result
}

function Invoke-KubectlRaw {
    param([string[]]$KArgs)
    $env:KUBECONFIG = $KubeconfigPath
    return & kubectl $KArgs 2>&1
}

# ---------------------------------------------------------------------------
# 1. Node readiness
# ---------------------------------------------------------------------------
function Test-NodeReadiness {
    Write-Step "=== 1. Node readiness ==="

    $allNodes    = @(Get-AllLinuxNodeNames) + @(Get-AllWindowsNodeNames)
    $nodesJson   = Invoke-KubectlRaw @('get', 'nodes', '-o', 'json') | ConvertFrom-Json
    $clusterNodes = @($nodesJson.items | ForEach-Object { $_.metadata.name })

    foreach ($name in $allNodes) {
        $nodeObj   = $nodesJson.items | Where-Object { $_.metadata.name -eq $name }
        if (-not $nodeObj) {
            Record-Result $false "Node '$name' exists in cluster"
            continue
        }
        Record-Result $true "Node '$name' exists in cluster"

        $readyCond = $nodeObj.status.conditions | Where-Object { $_.type -eq 'Ready' }
        $isReady   = $readyCond -and $readyCond.status -eq 'True'
        Record-Result $isReady "Node '$name' Ready"
    }
}

# ---------------------------------------------------------------------------
# 2. System pod health
# ---------------------------------------------------------------------------
function Test-SystemPods {
    Write-Step "=== 2. System pod health ==="

    $pods = Invoke-KubectlRaw @('get', 'pods', '-n', 'kube-system', '--no-headers') 2>$null

    $crashLoops = @($pods | Where-Object { $_ -match 'CrashLoopBackOff|Error\b|OOMKilled' })
    $crashDetail = if ($crashLoops.Count -gt 0) { "$($crashLoops.Count) unhealthy pod(s)" } else { '' }
    Record-Result ($crashLoops.Count -eq 0) "No CrashLoopBackOff/Error pods in kube-system" $crashDetail

    $coreDns = @($pods | Where-Object { $_ -match 'coredns' -and $_ -match '\bRunning\b' })
    Record-Result ($coreDns.Count -gt 0) "CoreDNS pods Running" "count=$($coreDns.Count)"
}

# ---------------------------------------------------------------------------
# 3. CNI-specific checks
# ---------------------------------------------------------------------------
function Test-CNIHealth {
    Write-Step "=== 3. CNI health ($($script:CNIPlugin)) ==="

    switch ($script:CNIPlugin) {
        'multus' {
            $dsJson = Invoke-KubectlRaw @('get', 'ds', 'kube-multus-ds', '-n', 'kube-system', '-o', 'json') |
                ConvertFrom-Json
            $desired = [int]$dsJson.status.desiredNumberScheduled
            $ready   = [int]$dsJson.status.numberReady
            Record-Result ($desired -gt 0 -and $ready -eq $desired) `
                "Multus DaemonSet ready" "ready=$ready desired=$desired"

            $nadCrd = Invoke-KubectlRaw @('get', 'crd', 'network-attachment-definitions.k8s.cni.cncf.io')
            Record-Result ($LASTEXITCODE -eq 0) "NetworkAttachmentDefinition CRD registered"
        }
        'cilium' {
            $cilPods = @(Invoke-KubectlRaw @('get', 'pods', '-n', 'kube-system', '-l', 'k8s-app=cilium',
                '--no-headers') | Where-Object { $_ -match '\bRunning\b' })
            Record-Result ($cilPods.Count -gt 0) "Cilium agent pods Running" "count=$($cilPods.Count)"
        }
        'flannel+cilium' {
            # Flannel is embedded — no separate pod. Check that Cilium chained pods are Running on Linux nodes only.
            $cilPods = @(Invoke-KubectlRaw @('get', 'pods', '-n', 'kube-system', '-l', 'k8s-app=cilium',
                '--no-headers') | Where-Object { $_ -match '\bRunning\b' })
            Record-Result ($cilPods.Count -gt 0) "Cilium chained agent pods Running (Linux nodes)" "count=$($cilPods.Count)"

            # Confirm no Cilium pod is scheduled on Windows nodes
            $winNodes = @(Get-AllWindowsNodeNames)
            if ($winNodes.Count -gt 0) {
                $cilPodsOnWin = @(Invoke-KubectlRaw @('get', 'pods', '-n', 'kube-system', '-l', 'k8s-app=cilium',
                    '-o', 'wide', '--no-headers') | Where-Object {
                        $line = $_
                        $winNodes | Where-Object { $line -match $_ }
                    })
                Record-Result ($cilPodsOnWin.Count -eq 0) "No Cilium pod on Windows nodes (Windows uses Flannel-only)" "found=$($cilPodsOnWin.Count)"
            }

            # Flannel is embedded — no separate DaemonSet to check
            Record-Result $true "Flannel embedded (no separate DaemonSet — this is normal for k3s)"
        }
        'calico' {
            $calicoPods = @(Invoke-KubectlRaw @('get', 'pods', '-n', 'calico-system', '-l', 'k8s-app=calico-node',
                '--no-headers') | Where-Object { $_ -match '\bRunning\b' })
            Record-Result ($calicoPods.Count -gt 0) "Calico node pods Running" "count=$($calicoPods.Count)"
        }
        default {
            # flannel / none — embedded, no separate pod to check
            $flannelPods = @(Invoke-KubectlRaw @('get', 'pods', '-n', 'kube-system',
                '--no-headers') | Where-Object { $_ -match 'flannel' -and $_ -match '\bRunning\b' })
            if ($flannelPods.Count -gt 0) {
                Record-Result $true "Flannel pods Running (embedded k3s flannel)" "count=$($flannelPods.Count)"
            } else {
                Record-Result $true "Flannel embedded (no separate DaemonSet — this is normal for k3s)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 4-10. Pod connectivity tests
# ---------------------------------------------------------------------------
function Deploy-TestDaemonSet {
    Write-Step "=== 4. Deploy test DaemonSet ==="

    # Create namespace
    $nsExists = Invoke-KubectlRaw @('get', 'namespace', $TestNamespace) 2>$null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Kubectl @('create', 'namespace', $TestNamespace)
        Write-Step "Created namespace '$TestNamespace'"
    }

    # DaemonSet YAML — alpine with a tiny HTTP server on 8080
    $yaml = @"
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: $DaemonSetName
  namespace: $TestNamespace
  labels:
    app: verify-ping
spec:
  selector:
    matchLabels:
      app: verify-ping
  template:
    metadata:
      labels:
        app: verify-ping
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
        - operator: Exists
      terminationGracePeriodSeconds: 5
      containers:
        - name: ping
          image: alpine:3.19
          command:
            - sh
            - -c
            - |
              printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK' > /tmp/http_ok
              while true; do nc -l -p 8080 < /tmp/http_ok 2>/dev/null; done &
              sleep infinity
          ports:
            - containerPort: 8080
              protocol: TCP
          resources:
            requests:
              cpu: "10m"
              memory: "16Mi"
            limits:
              cpu: "100m"
              memory: "32Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: $ServiceName
  namespace: $TestNamespace
spec:
  selector:
    app: verify-ping
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
  type: ClusterIP
"@
    $tmpYaml = [System.IO.Path]::GetTempFileName() + '.yaml'
    Set-Content -Path $tmpYaml -Value $yaml -Encoding UTF8

    try {
        Invoke-Kubectl @('apply', '-f', $tmpYaml)
    } finally {
        Remove-Item $tmpYaml -ErrorAction SilentlyContinue
    }

    Write-Success "Test DaemonSet + Service applied"
}

function Wait-TestPodsReady {
    Write-Step "=== 5. Wait for test pods Running ==="

    $null = Wait-Until -TimeoutSec 300 -PollSec 10 -Description 'test pods Running' -Condition {
        $dsJson  = Invoke-KubectlRaw @('get', 'ds', $DaemonSetName, '-n', $TestNamespace, '-o', 'json') |
            ConvertFrom-Json
        $desired = [int]$dsJson.status.desiredNumberScheduled
        $ready   = [int]$dsJson.status.numberReady
        Write-Step "  DaemonSet ${DaemonSetName}: $ready/$desired Ready"
        return ($desired -gt 0 -and $ready -eq $desired)
    }

    $podsJson = Invoke-KubectlRaw @('get', 'pods', '-n', $TestNamespace,
        '-l', 'app=verify-ping', '-o', 'json') | ConvertFrom-Json
    $pods = @($podsJson.items)
    Record-Result ($pods.Count -gt 0) "Test DaemonSet pods Running" "count=$($pods.Count)"
    return $pods
}

function Test-CrossNodeConnectivity {
    param([object[]]$Pods)
    Write-Step "=== 6-8. Cross-node connectivity (all node pairs) ==="

    # Group pods by node
    $podsByNode = @{}
    foreach ($p in $Pods) {
        $node = $p.spec.nodeName
        $ip   = $p.status.podIP
        $name = $p.metadata.name
        if (-not $podsByNode.ContainsKey($node)) { $podsByNode[$node] = @() }
        $podsByNode[$node] += @{ Name = $name; IP = $ip }
    }

    Write-Step "  Pod distribution:"
    foreach ($node in ($podsByNode.Keys | Sort-Object)) {
        foreach ($pod in $podsByNode[$node]) {
            Write-Step "    $($pod.Name) on $node → $($pod.IP)"
        }
    }

    $nodeNames = @($podsByNode.Keys | Sort-Object)
    if ($nodeNames.Count -lt 2) {
        Write-Warn "Only 1 Linux node found — cross-node test requires 2+. Skipping cross-node tests."
        Record-Result $false "Cross-node connectivity (2+ nodes required)" "only $($nodeNames.Count) node"
        return
    }

    # Test every unique ordered pair (A→B) for ICMP + HTTP
    # For N nodes: N*(N-1) directed pairs, or N*(N-1)/2 unique undirected pairs
    # We test each undirected pair in both directions for ICMP; one direction for HTTP
    for ($i = 0; $i -lt $nodeNames.Count; $i++) {
        for ($j = $i + 1; $j -lt $nodeNames.Count; $j++) {
            $nodeA = $nodeNames[$i]
            $nodeB = $nodeNames[$j]
            $podA  = $podsByNode[$nodeA][0]
            $podB  = $podsByNode[$nodeB][0]

            Write-Step "  --- Pair: $nodeA ↔ $nodeB ---"

            # --- ICMP ping A→B ---
            Write-Step "  [6] ICMP $($podA.Name) ($nodeA) → $($podB.IP) ($nodeB)..."
            try {
                $pingOut = Invoke-KubectlRaw @('exec', '-n', $TestNamespace, $podA.Name, '--',
                    'ping', '-c', '4', '-W', '2', $podB.IP)
                $pingOk = ($LASTEXITCODE -eq 0) -and ($pingOut | Where-Object { $_ -match '4 received|4 packets received' })
                Record-Result $pingOk "ICMP ping $nodeA → $nodeB ($($podB.IP))" `
                    ($pingOut | Where-Object { $_ -match 'packet' } | Select-Object -Last 1)
            } catch {
                Record-Result $false "ICMP ping $nodeA → $nodeB" "$_"
            }

            # --- ICMP ping B→A ---
            Write-Step "  [6] ICMP $($podB.Name) ($nodeB) → $($podA.IP) ($nodeA)..."
            try {
                $pingOut2 = Invoke-KubectlRaw @('exec', '-n', $TestNamespace, $podB.Name, '--',
                    'ping', '-c', '4', '-W', '2', $podA.IP)
                $pingOk2 = ($LASTEXITCODE -eq 0) -and ($pingOut2 | Where-Object { $_ -match '4 received|4 packets received' })
                Record-Result $pingOk2 "ICMP ping $nodeB → $nodeA ($($podA.IP))" `
                    ($pingOut2 | Where-Object { $_ -match 'packet' } | Select-Object -Last 1)
            } catch {
                Record-Result $false "ICMP ping $nodeB → $nodeA" "$_"
            }

            # --- HTTP curl A→B ---
            Write-Step "  [7] HTTP $($podA.Name) → http://$($podB.IP):8080..."
            try {
                Start-Sleep -Seconds 1
                $curlOut = Invoke-KubectlRaw @('exec', '-n', $TestNamespace, $podA.Name, '--',
                    'wget', '-qO-', '--timeout=5', "http://$($podB.IP):8080")
                $curlOk = ($LASTEXITCODE -eq 0)
                $curlDetail = $(if ($curlOut) { $curlOut -join ' ' } else { 'no response' })
                Record-Result $curlOk "HTTP wget $nodeA → pod on $nodeB ($($podB.IP):8080)" $curlDetail
            } catch {
                Record-Result $false "HTTP wget $nodeA → pod on $nodeB" "$_"
            }

            # --- DNS inside A ---
            Write-Step "  [8] DNS in $($podA.Name)..."
            try {
                $dnsOut = Invoke-KubectlRaw @('exec', '-n', $TestNamespace, $podA.Name, '--',
                    'nslookup', 'kubernetes.default.svc.cluster.local')
                $dnsOk = ($LASTEXITCODE -eq 0) -and ($dnsOut | Where-Object { $_ -match 'Address' })
                Record-Result $dnsOk "DNS kubernetes.default.svc.cluster.local (from $nodeA)" `
                    ($dnsOut | Where-Object { $_ -match 'Address' } | Select-Object -Last 1)
            } catch {
                Record-Result $false "DNS resolution from $nodeA" "$_"
            }
        }
    }
}

function Test-ClusterIPService {
    param([object[]]$Pods)
    Write-Step "=== 9. ClusterIP service reachability ==="

    # Get the service ClusterIP
    try {
        $svcJson = Invoke-KubectlRaw @('get', 'svc', $ServiceName, '-n', $TestNamespace, '-o', 'json') |
            ConvertFrom-Json
        $clusterIP = $svcJson.spec.clusterIP
        if (-not $clusterIP -or $clusterIP -eq 'None') {
            Record-Result $false "ClusterIP service has a valid IP" "clusterIP=$clusterIP"
            return
        }
        Record-Result $true "ClusterIP service IP assigned" "IP=$clusterIP"

        # Pick any pod as the source for the curl
        $srcPod = $Pods[0].metadata.name
        Write-Step "  curl from $srcPod → ${clusterIP}:8080..."
        Start-Sleep -Seconds 2
        $curlOut = Invoke-KubectlRaw @('exec', '-n', $TestNamespace, $srcPod, '--',
            'wget', '-qO-', '--timeout=5', "http://${clusterIP}:8080")
        $curlOk  = ($LASTEXITCODE -eq 0)
        $clusterDetail = if ($curlOut) { ($curlOut -join ' ').Substring(0, [Math]::Min(60, ($curlOut -join ' ').Length)) } else { 'no response' }
        Record-Result $curlOk "ClusterIP service reachable (wget → ${clusterIP}:8080)" $clusterDetail
    } catch {
        Record-Result $false "ClusterIP service reachability" "$_"
    }
}

# ---------------------------------------------------------------------------
# 10. Windows node check
# ---------------------------------------------------------------------------
function Test-WindowsNodes {
    Write-Step "=== 10. Windows node checks ==="

    $winNames = @(Get-AllWindowsNodeNames)
    if ($winNames.Count -eq 0) {
        Write-Step "  No Windows nodes configured — skipping"
        return
    }

    foreach ($nodeName in $winNames) {
        # Check node label
        try {
            $nodeJson  = Invoke-KubectlRaw @('get', 'node', $nodeName, '-o', 'json') | ConvertFrom-Json
            $osLabel   = $nodeJson.metadata.labels.'kubernetes.io/os'
            Record-Result ($osLabel -eq 'windows') "Windows node '$nodeName' labeled kubernetes.io/os=windows" `
                "actual=$osLabel"

            $readyCond = $nodeJson.status.conditions | Where-Object { $_.type -eq 'Ready' }
            $isReady   = $readyCond -and $readyCond.status -eq 'True'
            Record-Result $isReady "Windows node '$nodeName' is Ready"
        } catch {
            Record-Result $false "Windows node '$nodeName' info retrievable" "$_"
            continue
        }

        # Schedule a pause container (Windows pause image) — quickly verify scheduling works
        $pauseYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: win-verify-$($nodeName -replace '-','')
  namespace: $TestNamespace
spec:
  nodeSelector:
    kubernetes.io/hostname: $nodeName
  tolerations:
    - operator: Exists
  os:
    name: windows
  containers:
    - name: pause
      image: mcr.microsoft.com/oss/kubernetes/pause:3.9
      resources:
        requests:
          cpu: "10m"
          memory: "16Mi"
"@
        $tmpWin = [System.IO.Path]::GetTempFileName() + '.yaml'
        Set-Content -Path $tmpWin -Value $pauseYaml -Encoding UTF8
        try {
            Write-Step "  Scheduling Windows pause pod on '$nodeName'..."
            Invoke-KubectlRaw @('apply', '-f', $tmpWin) | Out-Null

            # Wait up to 5 min for Running (Windows image pull can be slow)
            $winPodName = "win-verify-$($nodeName -replace '-','')"
            $winOk = Wait-Until -TimeoutSec 300 -PollSec 15 -Description "Windows pod Running on '$nodeName'" -Condition {
                $phase = Invoke-KubectlRaw @('get', 'pod', $winPodName, '-n', $TestNamespace,
                    '-o', 'jsonpath={.status.phase}') 2>$null
                Write-Step "  Windows pause pod phase: $phase"
                return ($phase -eq 'Running')
            } -NoThrow
            Record-Result $winOk "Windows pause pod scheduled + Running on '$nodeName'"
        } finally {
            Remove-Item $tmpWin -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 11. Hubble observability (cilium + flannel+cilium only)
# ---------------------------------------------------------------------------
function Test-HubbleObservability {
    param([object[]]$Pods)
    Write-Step "=== 11. Hubble observability ==="

    # 1. Hubble Relay deployment health
    $relayRaw = Invoke-KubectlRaw @('get', 'deployment', 'hubble-relay', '-n', 'kube-system', '-o', 'json')
    if ($LASTEXITCODE -ne 0) {
        Record-Result $false "Hubble Relay deployment exists in kube-system"
        return
    }
    $relayDeploy  = $relayRaw | ConvertFrom-Json
    $relayReady   = if ($relayDeploy.status.PSObject.Properties['readyReplicas']) { [int]$relayDeploy.status.readyReplicas } else { 0 }
    $relayDesired = [int]$relayDeploy.spec.replicas
    Record-Result ($relayReady -gt 0 -and $relayReady -eq $relayDesired) `
        "Hubble Relay deployment ready" "ready=$relayReady/$relayDesired"

    # 2. Hubble UI deployment health (present when hubble.ui.enabled: true)
    $uiRaw = Invoke-KubectlRaw @('get', 'deployment', 'hubble-ui', '-n', 'kube-system', '-o', 'json')
    if ($LASTEXITCODE -eq 0) {
        $uiDeploy   = $uiRaw | ConvertFrom-Json
        $uiReady    = if ($uiDeploy.status.PSObject.Properties['readyReplicas']) { [int]$uiDeploy.status.readyReplicas } else { 0 }
        $uiDesired  = [int]$uiDeploy.spec.replicas
        Record-Result ($uiReady -gt 0 -and $uiReady -eq $uiDesired) `
            "Hubble UI deployment ready" "ready=$uiReady/$uiDesired"
    }

    # 3. Verify flows via hubble CLI inside a Cilium pod (no host-side tooling needed).
    #    Traffic was generated by cross-node + ClusterIP tests above.
    #    hubble observe connects to the per-node agent unix socket inside the container.
    $ciliumPodName = (Invoke-KubectlRaw @('get', 'pods', '-n', 'kube-system',
        '-l', 'k8s-app=cilium',
        '-o', 'jsonpath={.items[0].metadata.name}')) -join ''

    if (-not $ciliumPodName) {
        Record-Result $false "Hubble: Cilium pod found for flow query"
        return
    }

    Write-Step "  Querying Hubble flows via pod '$ciliumPodName'..."
    try {
        $flowOut = Invoke-KubectlRaw @('exec', '-n', 'kube-system', $ciliumPodName, '--',
            'hubble', 'observe', '--namespace', $TestNamespace, '--last', '200')

        # A valid flow line contains a verdict word and the namespace
        $flowLines = @($flowOut | Where-Object {
            $_ -match 'FORWARDED|DROPPED|REDIRECTED|TO-OVERLAY|TO-STACK|TO-ENDPOINT' -and
            $_ -match $TestNamespace
        })
        Record-Result ($flowLines.Count -gt 0) `
            "Hubble flows captured for namespace '$TestNamespace'" `
            "flows=$($flowLines.Count)"

        if ($flowLines.Count -gt 0) {
            Write-Step "    Sample: $($flowLines[0])"
        }
    } catch {
        Record-Result $false "Hubble observe exec" "$_"
    }
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
function Remove-TestResources {
    Write-Step "Cleaning up namespace '$TestNamespace'..."
    # Force-delete all pods first to avoid finalizer hang during namespace deletion
    Invoke-KubectlRaw @('delete', 'pods', '--all', '-n', $TestNamespace, '--force', '--grace-period=0') | Out-Null
    Invoke-KubectlRaw @('delete', 'namespace', $TestNamespace, '--ignore-not-found') | Out-Null
    Write-Success "Test namespace deleted"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-Verify {
    Write-PhaseHeader '10' "Verify cluster health and cross-node connectivity"

    $env:KUBECONFIG = $KubeconfigPath
    Assert-True (Test-Path $KubeconfigPath) "kubeconfig not found at $KubeconfigPath. Run Export-KubeConfig.ps1 first."

    # Verify cluster is reachable
    Invoke-Step "API server reachable" {
        $null = kubectl cluster-info --request-timeout=15s 2>&1
        Assert-True ($LASTEXITCODE -eq 0) "Cannot reach cluster API. Ensure the cluster is running and kubeconfig is valid."
    }

    $startTs = Get-Date

    Test-NodeReadiness
    Test-SystemPods
    Test-CNIHealth

    if (-not $HealthOnly) {
        Deploy-TestDaemonSet
        $pods = Wait-TestPodsReady

        if ($pods -and $pods.Count -gt 0) {
            Test-CrossNodeConnectivity -Pods $pods
            Test-ClusterIPService      -Pods $pods
            # Hubble: must run after traffic is generated and before namespace cleanup
            if ($script:CNIPlugin -in @('cilium', 'flannel+cilium')) {
                Test-HubbleObservability -Pods $pods
            }
        } else {
            Record-Result $false "Test pods scheduled" "no pods found in $TestNamespace"
        }

        Test-WindowsNodes

        if (-not $SkipCleanup) {
            Remove-TestResources
        } else {
            Write-Warn "-SkipCleanup: test namespace '$TestNamespace' left intact for inspection"
            Write-Host "  kubectl get pods -n $TestNamespace -o wide" -ForegroundColor Cyan
        }
    }

    $elapsed = [math]::Round(((Get-Date) - $startTs).TotalSeconds, 1)

    # --- Summary ---
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host "  VERIFICATION SUMMARY  ($elapsed s)" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
    foreach ($line in $script:Results) {
        $color = if ($line -match '^\s+PASS') { 'Green' } else { 'Red' }
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ''
    $totalColor = if ($script:FailCount -eq 0) { 'Green' } else { 'Red' }
    Write-Host "  PASS: $($script:PassCount)   FAIL: $($script:FailCount)" -ForegroundColor $totalColor
    Write-Host ('=' * 72) -ForegroundColor Cyan

    if ($script:FailCount -gt 0) {
        throw "Verification failed: $($script:FailCount) check(s) did not pass. See summary above."
    }

    Set-PhaseComplete 'verify'
    Write-PhaseDone '10'
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($Force) { Reset-PhaseComplete 'verify' }

if (-not $Force -and (Test-PhaseComplete 'verify') -and -not $HealthOnly) {
    Write-Success "Verification phase already complete — pass -Force to re-run"
} else {
    Invoke-Verify
}
