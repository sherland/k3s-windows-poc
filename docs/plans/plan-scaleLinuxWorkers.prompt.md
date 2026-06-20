# Plan: Scale-LinuxWorkers.ps1

## Goal
New `Scale-LinuxWorkers.ps1` at repo root to scale Linux worker count up or down after a scenario is already running. After any scaling operation, `config/variables.ps1` is updated with the new node count.

---

## Parameters
- `-TargetCount [int]` — required; desired number of Linux workers
- `-DrainTimeoutSec [int]` — default 300; drain timeout per node (0 = `--force --disable-eviction`, skip PDB checks but attempt eviction)
- `-NodeDeleteTimeoutSec [int]` — default 60; how long to wait for `kubectl delete node` to complete (0 = fire-and-forget)
- `-WhatIf` — preview without executing

---

## Key Design Decisions
- Script lives at repo root (like Run-ScenarioX.ps1)
- Scale-down removes highest-index node first (lnx-03 before lnx-02)
- Incremental variables.ps1 update: updated AFTER each individual node success (resilient to mid-run failure)
- Scale-up: update variables.ps1 FIRST to new count, then delegate to New-LinuxNodes.ps1 + Join-Nodes.ps1 (they're idempotent via sentinels)
- Drain timeout=0: `kubectl drain --force --disable-eviction --ignore-daemonsets --delete-emptydir-data`
- Drain timeout>0: `kubectl drain --timeout=Xs --ignore-daemonsets --delete-emptydir-data`
- No `-Force` flag passed to sub-scripts — relies on sentinel idempotency
- Seed ISOs removed on scale-down (`output/seed-isos/<NodeName>.iso`)

---

## variables.ps1 update pattern
```powershell
$varPath = Join-Path $PSScriptRoot 'config\variables.ps1'
$raw = Get-Content $varPath -Raw
$updated = $raw -replace '(\$script:LinuxWorkerCount\s*=\s*)\d+', "`${1}$newCount"
Set-Content $varPath $updated -NoNewline
```
Applied after each node operation (scale-down) or before calling sub-scripts (scale-up).

---

## Scale-Up Flow
1. Validate: base linux VHDX exists; CP is running; kubeconfig present
2. Write new `$script:LinuxWorkerCount` to variables.ps1 (before calling sub-scripts so they enumerate correctly)
3. `& "$PSScriptRoot\scripts\New-LinuxNodes.ps1"` — creates only the new VMs (existing ones skip via sentinel)
4. `& "$PSScriptRoot\scripts\Join-Nodes.ps1"` — joins only the new nodes (existing ones skip via sentinel)

---

## Scale-Down Flow (per node, highest index first)
For each node index from `currentCount` down to `targetCount + 1`:
1. `kubectl cordon <NodeName>`
2. `kubectl drain <NodeName> [--timeout=Xs | --force --disable-eviction] --ignore-daemonsets --delete-emptydir-data`
3. `kubectl delete node <NodeName>` — if `NodeDeleteTimeoutSec > 0`, poll until node is gone from cluster; else fire-and-forget
4. SSH: `sudo systemctl stop k3s-agent` (best-effort — catch error, emit warning, never fatal)
5. Stop-VM -TurnOff -Force → Remove-VM -Force → Remove-Item VHDX (via `Get-NodeVhdxPath`)
6. Remove `output/seed-isos/<NodeName>.iso` if it exists
7. `Reset-PhaseComplete "node-<NodeName>-ready"` and `Reset-PhaseComplete "node-<NodeName>"`
8. `Set-LinuxWorkerCount -Count ($i - 1)` — per-node update so partial runs leave variables.ps1 accurate

---

## Files to Create/Modify
- NEW: `Scale-LinuxWorkers.ps1` (repo root)
- MODIFY (at runtime): `config/variables.ps1` — only the `$script:LinuxWorkerCount` line is patched; no structural changes

---

## Relevant Existing Patterns to Reuse
- `Remove-VMAndDisks` in `scripts/Remove-Cluster.ps1` — reference pattern for stop+remove VM+disk (inlined, not dot-sourced, to avoid ShouldProcess and Remove-Cluster.ps1's own parameter set)
- `Invoke-Kubectl` local function pattern from `scripts/Join-Nodes.ps1` — define same local function using `output/admin-kubeconfig.yaml`
- `Wait-Until`, `Get-VMIPAddress`, `Invoke-SshCommand`, `Test-PhaseComplete`, `Set-PhaseComplete`, `Reset-PhaseComplete`, `Write-Step`, `Write-Warn`, `Write-Success` from `scripts/Helpers.ps1`
- `Get-NodeVhdxPath` from `scripts/Helpers.ps1`
- `$script:LinuxWorkerPrefix`, `$script:SshKeyPath`, `$script:LinuxAdminUser`, `$script:NodeJoinTimeoutSec`, `$script:NodeReadyTimeoutSec`, `$script:VMBootTimeoutSec` from `config/variables.ps1`

---

## Phase 5 — Docs Update (final step, after script is verified working)
Update all documentation to reflect the new script:

### AGENTS.md
- `## Key Entry Points` table — add row: `Scale-LinuxWorkers.ps1 | Scale Linux workers up or down post-cluster`
- `## Script Inventory` table — add row after `Update-KubeConfig.ps1`: `Scale-LinuxWorkers.ps1 | Working | Scale Linux workers — drain/delete/stop for scale-down, create/join for scale-up; patches variables.ps1`
- `## Common Tasks` section — add `**Scale Linux workers**` entry with usage example

### README.md
- `## Repository Layout` scripts/ tree — add `Scale-LinuxWorkers.ps1`
- Operations/recreating section — add scale usage example

### docs/architecture.md
- `## 3. How Nodes Are Created from Golden Images` — add note that `Scale-LinuxWorkers.ps1` reuses this mechanism out-of-band (post-cluster)
- `## 10. Phase Map` footer — add note that `Scale-LinuxWorkers.ps1` is a post-cluster utility running Phases 4+7 for new nodes only

---

## Verification
1. `.\Scale-LinuxWorkers.ps1 -TargetCount 3 -WhatIf` — preview only; no VMs created; `variables.ps1` unchanged
2. `.\Scale-LinuxWorkers.ps1 -TargetCount 3` — `k8s-lnx-03` VM created, joined, Ready in kubectl; `variables.ps1` line reads `= 3`
3. `.\Scale-LinuxWorkers.ps1 -TargetCount 1` — `k8s-lnx-02` drained first, deleted from cluster, VM + VHDX + seed ISO gone, sentinels removed; `variables.ps1` reads `= 1`
4. `.\Scale-LinuxWorkers.ps1 -TargetCount 1 -DrainTimeoutSec 0` — drain uses `--force --disable-eviction`
5. `.\Scale-LinuxWorkers.ps1 -TargetCount 2` when already at 2 — exits with "Already at target count, nothing to do"
6. Kill script mid-scale-down after first node removed — re-run picks up correctly; `variables.ps1` reflects actual cluster state

---

## Exclusions
- Windows nodes not in scope
- No changes to `Main.ps1` phase orchestration
- No changes to `Run-ScenarioX.ps1` scripts
