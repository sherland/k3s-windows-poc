# Plan: Dependency update — October 2026

## Goal
Bring every pinned component in the repo to its latest version that is **compatible across all six
scenarios (A–F)**, re-verify the previously documented upgrade blockers, and validate the result
end-to-end (`Run-AllScenarios.ps1 -DeleteGoldenImages`).

Branch: `deps/update-2026-10`, created from the tip of `deps/update-cni-and-dependencies-2026-09`
(the September bump round). That branch was actually merged to `main` via PR #11 on 2026-09-14,
over a month before this plan's research date, so by the time this round started, its content was
already on `main`; this branch just happened to be created from the feature branch's tip directly
rather than from `main` after the merge. Content-identical either way (confirmed: zero tree diff
between the two), but worth naming precisely since getting a branch's starting point wrong undermines
trust in anything computed relative to it, including the "current" version numbers in the table
below, which were cross-checked directly against `main`'s actual `config/variables.ps1` and do match.

Research date: 2026-10-23. Sources: GitHub releases API for each project, containerd `RELEASES.md`,
Kubernetes `CHANGELOG-1.36.md`, Cilium/Calico/Antrea compatibility docs, `helm show values`,
`docker manifest inspect`.

---

## 1. Inventory — current vs. latest

| Component | Where pinned | Current | Latest available | Target | Notes |
|---|---|---|---|---|---|
| k3s (Linux) / kubelet + kube-proxy (Windows) | `K3sVersion`, hcl defaults, `02-*.sh` | v1.35.8+k3s1 | v1.37.1+k3s1 (also 1.36.5, 1.35.9) | **v1.36.5+k3s1** | 1.37 blocked by Cilium (§2.3) |
| containerd (Windows) | `ContainerdVersion`, hcl, `03-containerd.ps1` | 1.7.35 | 2.4.2 / 2.3.7 (LTS) / 1.7.36 (EOL) | **2.3.7** | 1.7 EOL 2026-09-30 (§2.1) |
| pause image (Windows sandbox) | `03-containerd.ps1`, `04-install-k8s-binaries.ps1`, `Verify-Cluster.ps1` | mcr.microsoft.com/oss/kubernetes/pause:3.9 | registry.k8s.io/pause:3.10.2 | **registry.k8s.io/pause:3.10.2** | k8s 1.36 default; has native ltsc2025 (10.0.26100) variant, 3.9 only goes to ltsc2022 |
| flannel (Windows flanneld + CNI) | `FlannelVersion` | v0.28.9 | v0.28.10 | **v0.28.10** | Asset naming unchanged (`flannel-vX-windows-amd64.tar.gz`) |
| windows-container-networking | `WinsCniVersion` | v0.3.3 | v0.3.3 | — | already latest |
| Multus | `MultusVersion`, `multus-daemonset.yaml` | v4.3.1 | v4.3.1 | — | already latest |
| containernetworking/plugins | `CniPluginsVersion`; **hardcoded** in `04-install-k8s-binaries.ps1` | v1.9.1 | v1.9.1 | — | already latest; de-hardcode (§4, C1) |
| Cilium | `CiliumVersion` | 1.20.1 | 1.20.4 | **1.20.4** | patch-only; supports k8s 1.33–1.36 |
| Calico (tigera-operator) | `CalicoVersion` | v3.32.2 | v3.33.0 | **v3.33.0** | supports k8s 1.35–1.37; chart CR toggles unchanged (§2.5) |
| Antrea | `AntreaVersion` | 2.7.0 | 2.7.0 | — | already latest; **fix stale `2.6.2` fallbacks** |
| packer-plugin-hyperv | `required_plugins` in both `.pkr.hcl` | `>= 1.1.3` | 1.1.5 | **`>= 1.1.5`** | host already has 1.1.5 |
| Packer | winget (unpinned) | host 1.16.1 | 1.16.2 | — | unpinned; `required_version >= 1.10.0` is fine |
| Helm | winget (unpinned) | host v4.2.3 | v4.3.1 | — | unpinned; Sept round already validated on Helm 4 |
| kubectl (host) | winget (unpinned) | **PATH resolves Chocolatey 1.32.3** (winget has 1.37.0) | 1.37.1 | warn on skew | §2.6 |
| Pester | CI `-MinimumVersion 5.5.0` | CI resolves to 6.x; host 6.2.0 | 6.2.0 | **pin `6.*` explicitly** | docs still say 5.5 |
| actions/checkout | CI | v4 | v7.0.1 | **v7** | |
| actions/upload-artifact | CI | v4 | v7.0.2 | **v7** | |
| Ubuntu (Linux base) | `UbuntuReleasesBaseUrl`, ISO regex | 24.04 (auto-resolves 24.04.5) | 26.04.1 LTS | **stretch** (§5) | |
| Windows Server | `WindowsNodeSpecs` | WS2025 | WS2025 | — | WS2022 blocker unchanged (§2.4) |

---

## 2. Previously documented blockers — re-verified

### 2.1 containerd pinned to 1.7.x — the stated reason was wrong, and the pin is now a liability
Docs (`AGENTS.md`, `variables.ps1`, `03-containerd.ps1`, `winserver.pkr.hcl`,
`tests/ConfigVariables.Tests.ps1`) claim *"containerd v2.x breaks the CRI v1 API kubelet expects"*.
That is incorrect: containerd 2.0 removed CRI **v1alpha2**; CRI **v1** is the only CRI API in 2.x
(containerd `RELEASES.md` lists CRI v1 for every 2.x line). What actually changes in 2.x is the
**config format** (v3 schema: `io.containerd.grpc.v1.cri` split into `io.containerd.cri.v1.runtime`
/ `io.containerd.cri.v1.images`; `sandbox_image` → `pinned_images.sandbox`; `bin_dir` → `bin_dirs`).
A v2 config with v2 keys appended later (as `04-install-k8s-binaries.ps1` does) is the likely
source of the original breakage.

Facts that force the move now:
- containerd 1.7 reached **End of Life on 2026-09-30**.
- containerd compatibility matrix: k8s 1.36 → **2.3.0+, 2.2.0+**; k8s 1.37 → 2.4.0+, 2.3.0+.
- k3s v1.36.5 itself embeds containerd **v2.3.4** on Linux.

→ Target **2.3.7** (2.3 is the LTS line, supported to 2028-04-30, covers k8s 1.36 *and* 1.37).
Windows tarball verified: still ships `containerd-shim-runhcs-v1.exe`, `containerd.exe`, `ctr.exe`.

### 2.2 "k3s v1.36 NOT usable — kubelet 1.36 removes the containerd 1.x cgroup-driver fallback"
Partly wrong: `CHANGELOG-1.36.md` — *"Deferred the removal of deprecated kubelet configuration flags
(and their related fallback behavior) from version 1.36 to 1.37, aligning with the end of
containerd v1.7 support."* Moot either way once Windows is on containerd 2.3 → **k8s 1.36 unblocked**.
k8s 1.36 urgent-upgrade notes contain nothing affecting our kubelet flags
(`--windows-service --hostname-override --node-ip --kubeconfig --config --root-dir --cert-dir
--register-with-taints --node-labels`) or winkernel kube-proxy; 1.36.1/1.36.5 contain Windows
kube-proxy fixes (stale HNS endpoint cleanup, LB-without-ports panic) — a plus.

### 2.3 New blocker: k8s 1.37 vs. Cilium
Cilium 1.20 (latest minor, 1.20.4) supports k8s **1.33–1.36** only. Scenarios C and E would run on an
unsupported k8s. Calico 3.33 (1.35–1.37) and Antrea would be fine. Since one `K3sVersion` serves all
scenarios → **k3s v1.36.5+k3s1** (latest 1.36 patch). Revisit when Cilium 1.21 ships.

### 2.4 WS2022 eval ISO (fwlink repointed to a WS2019 VHD)
Unchanged — still uses WS2025 for A/E/F. Not part of this round.

### 2.5 Calico 3.30+ two-phase Helm install
Still required. `helm show values` diff 3.32.2 → 3.33.0: same CR toggles
(`installation`/`apiServer`/`goldmane`/`whisker`), only `zapDevel` added and `dnsPolicy` removed —
neither used. 3.33 breaking changes reviewed (image consolidation into `quay.io/calico/calico`,
default CNI `cniVersion 1.0.0`, eBPF/kernel 5.15 regression, FIPS removal): none apply — we use the
operator (handles images), iptables data plane, VXLAN, Ubuntu 24.04 kernel 6.8, and containerd 2.x
on Linux via k3s. Verify the `k8s-app=calico-node` label is still used in E2E.

### 2.6 kubectl version skew (host)
`kubectl` on PATH is Chocolatey's 1.32.3, shadowing winget's 1.37.0. Against a 1.36 server this is
outside the ±1 minor skew policy. Not a repo bug, but Phase 0 should **warn** (not fail) when the
resolved kubectl client is more than one minor away from `K3sVersion`, printing the resolved path.

---

## 3. Antrea + containerd 2.x (highest-risk item)
Antrea's Windows doc requires containerd ≥ 1.6.18 (1.7+ recommended) and is silent on 2.x. Antrea
uses HostProcess containers (supported in containerd 2.x). Our Antrea glue only depends on the
containerd CNI **paths** (`C:\k\cni`, `C:\k\cni\config`) and restarting the `containerd` service —
both preserved in the v3 config. Scenario F is the explicit validation gate for this; if it fails
for a containerd-2-specific reason that cannot be fixed, fallback is documented in §6.

---

## 4. Implementation — commits (each one leaves Pester green)

**C1 — `chore: bump flannel, Cilium, Calico, packer-plugin-hyperv; fix Antrea pin drift`**
- `variables.ps1`: Flannel v0.28.10, Cilium 1.20.4, Calico v3.33.0.
- Flannel fallbacks in `04-install-k8s-binaries.ps1`, `04-k3s-agent.ps1` (legacy), `winserver.pkr.hcl`.
- `05-firstboot-setup.ps1` + `Join-Nodes.ps1` Antrea fallback `2.6.2` → `2.7.0`; `Run-ScenarioF.ps1` header.
- De-hardcode the Windows CNI-plugins URL: pass `CNI_PLUGINS_VERSION` from `CniPluginsVersion`
  through `Build-WindowsBase.ps1` → hcl var → `04-install-k8s-binaries.ps1` (fallback = pinned value).
- `required_plugins.hyperv.version = ">= 1.1.5"` in both templates.
- Extend `tests/RepoHygiene.Tests.ps1` drift checks: Antrea fallbacks, CNI-plugins fallback + hcl default.

**C2 — `feat: move Windows nodes to containerd 2.3 (v3 config) + pause 3.10.2`**
- `03-containerd.ps1`: default 2.3.7; write a native **version 3** `config.toml`:
  ```toml
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
  ```
  and **assert** at build time that `containerd config dump` reports `bin_dirs = ['C:\k\cni']` and
  the pinned sandbox image — containerd silently falls back to built-in defaults when the config
  file is missing, so a log-only check would not catch a wrong path (see §7).
- `04-install-k8s-binaries.ps1`: the "append `[cni]` section if missing" block keys on the v2
  section name and would append a v2 table to a v3 file → detect the v3 `cni` table instead (paths
  are already set by 03). Pause image in `kubelet-config.yaml` → 3.10.2.
- `Verify-Cluster.ps1` Windows pause pod → `registry.k8s.io/pause:3.10.2`.
- `variables.ps1` ContainerdVersion 2.3.7 + rewrite the compatibility comment block (§2.1/§2.2).
- `winserver.pkr.hcl` default + comment; `tests/ConfigVariables.Tests.ps1`: replace "stays on 1.x"
  with "is ≥ 2.2 (k8s 1.36 requires containerd 2.2+/2.3+ per containerd RELEASES.md)".
- Legacy `04-k3s-agent.ps1`: only keep pins in sync (not used by the Packer template).

**C3 — `chore: bump k3s v1.35.8+k3s1 -> v1.36.5+k3s1`**
- `variables.ps1`, `ubuntu.pkr.hcl`, `winserver.pkr.hcl` (`v1.36.5`), `02-install-k3s-binary.sh`,
  `02-k3s-server.sh`, comment examples in Windows scripts. Update compat comment
  (Cilium 1.33–1.36 ∩ Calico 1.35–1.37 ∩ Antrea → 1.36).

**C4 — `chore: CI actions v7, pin Pester 6; Phase 0 kubectl skew warning`**
- `pester-tests.yml`: checkout/upload-artifact v7, `Install-Module Pester -RequiredVersion`-style
  pin to 6.x (`-MinimumVersion 6.0.0 -MaximumVersion 6.999`).
- `Install-Prerequisites.ps1`: non-fatal kubectl client-skew warning.

**C5 — `docs: ...`** — after E2E: AGENTS.md (versions, scenario table timings/counts, rewritten
containerd pitfall), README.md, docs/architecture.md, Pester version references.

---

## 5. Stretch - Ubuntu 26.04 LTS (only after C1-C4 pass E2E) - DONE, 2026-10-24
26.04.1 is available. Changes that could bite: subiquity autoinstall schema, `sudo-rs` as default
sudo (we rely on `sudo -S` and `sudo -S env {{.Vars}}`), Rust coreutils, cgroup v2-only. Approach
taken: generalised the ISO-matching regex in `Build-LinuxBase.ps1` to derive both the expected
filename pattern and the error messages from `$script:UbuntuReleasesBaseUrl` instead of hardcoding
`24\.`, switched the base URL to `https://releases.ubuntu.com/26.04`, deleted only the Linux golden
image (kept the Windows ones), and rebuilt.

**Outcome: none of the flagged risks materialized.** The Linux base built cleanly in 13m24s against
`ubuntu-26.04.1-live-server-amd64.iso`: `sudo -S` / `sudo -S env {{.Vars}}` worked unchanged (no
`sudo-rs` incompatibility hit), the autoinstall schema (`version: 1`) was accepted as-is, and
`01-base.sh` / `02-install-k3s-binary.sh` / `03-cloud-init-clean.sh` all ran without modification.
Scenario A (flannel + Windows node): **33/33 PASS** (13.4 min total, including one recurrence of
the already-documented kubelet-first-boot flake on the *Windows* side, unrelated to the Linux
switch). Scenario C (Cilium/eBPF: the real stress test for 26.04's kernel, confirmed
`7.0.0-38-generic` via `kubectl get nodes -o wide`, i.e. cgroup v2-only): **33/33 PASS** (5.9 min).
Ran with no timebox, by explicit user instruction, so the revert-to-24.04 clause below was never
needed; recorded here for context on what the original plan allowed for, not what happened.

~~**Timebox**: if it fails for anything that is not a one-line fix, revert to 24.04 and record
findings here as a deferred item.~~ Not invoked; everything passed on the first attempt.

---

## 6. Validation
1. `Invoke-Pester -Path tests` after every commit (packer validate included when packer is on PATH).
2. After C4, via `run-elevated.ps1` (UAC approval by the user), monitoring `output/run.log`.
   Golden images **must** be rebuilt: Windows base bakes containerd + kubelet, Linux base bakes k3s.
   a. `Run-ScenarioA.ps1 -DeleteGoldenImages` — rebuilds both golden images; first signal for
      containerd 2.x + k8s 1.36 on Windows, without paying for five more scenarios if it fails.
   b. `Run-AllScenarios.ps1 -Scenarios B,C,D,E,F` — reuses the images from (a); F is the
      Antrea/containerd-2 gate.
   c. Elevated `Invoke-Pester -Path tests` (Helpers tests need admin, see §7).
3. Pass criteria: every scenario reports 100 % PASS in `Verify-Cluster.ps1` (A 33, B 39, C 33, D 30,
   E 40, F 43 or more).
4. On failure: diagnose from `output/run.log` / packer logs, fix, re-run only the failing scenario(s),
   then the full suite once at the end.

### Fallbacks
- Antrea breaks on containerd 2.x and cannot be fixed → keep containerd 2.3 (1.7 is EOL) and
  document Scenario F as known-broken pending upstream, rather than regress the whole repo.
- Windows kubelet/kube-proxy 1.36 issue → fall back to k3s v1.35.9+k3s1 (still compatible with
  containerd 2.3 and Cilium/Calico 3.33) and record the blocker.

---

## 7. Plan review — feasibility findings (verified before implementation)
- **containerd config schema**: validated offline with the real `containerd.exe` v2.3.7 Windows
  binary (`containerd --config <file> config dump`, no daemon started):
  - the proposed `version = 3` file loads; 2.3's native schema is `version = 4` (same table names),
    so it logs a one-line "migrated from version 3" warning. Kept at 3 because every 2.x line
    accepts it (2.2 does not know v4).
  - the **existing** v2 file is also auto-migrated correctly (`sandbox_image` → `pinned_images.sandbox`,
    `bin_dir` → `bin_dirs`), a known-good fallback if the v3 rewrite misbehaves.
  - pitfall found while testing: a missing/unreadable `--config` path is *silently* replaced by
    built-in defaults (`C:\Program Files\containerd\cni\bin`) → build-time assertion added to C2.
- **runhcs shim** still shipped in the 2.3.7 Windows tarball.
- **pause image** `registry.k8s.io/pause:3.10.2` manifest list includes Windows 10.0.17763,
  10.0.20348 and 10.0.26100 (WS2025) — native match for our WS2025 nodes.
- **Packer var plumbing** — `Build-WindowsBase.ps1` passes every version via `-var`; adding
  `cni_plugins_version` follows the existing pattern. `antreaVersion` already flows from
  `variables.ps1` into the node JSON, so the `2.6.2` fallbacks were only latent drift.
- **Golden image rebuild** — `Run-ScenarioX.ps1 -DeleteGoldenImages` exists per scenario, enabling
  the A-first validation order in §6.
- **Pester baseline** (non-elevated, Pester 6.2.0): 90 passed, 16 failed — all 16 are
  `Helpers.Tests.ps1`, which dot-sources `Helpers.ps1` (`#Requires -RunAsAdministrator`). Not a
  regression and not Pester-6 related; CI runners are admin. Run elevated as part of §6.
- **kubectl skew** — user is upgrading Chocolatey packages, which should replace the shadowing
  1.32.3; the Phase 0 warning stays as a guard.

## 7a. Findings from the real C2 build (Scenario A, 2026-10-23): lessons for the next offline check
The §7 offline validation above ran `containerd --config <file> config dump` from an interactive
`pwsh` 7.6.7 session on the build host. That masked two bugs that only surfaced once
`03-containerd.ps1` actually ran inside Packer's `powershell` provisioner on the WS2025 VM (which
runs **Windows PowerShell 5.1**, not `pwsh`; Packer's `powershell` provisioner type never uses
`pwsh` unless `use_pwsh` is set, which this template doesn't):

1. **Flag order, wrong on the first attempt.** The assertion was first written as
   `containerd.exe config dump --config <file>`. containerd's `--config` is a *global* flag and
   must precede the subcommand (`containerd --config <file> config dump`); the reversed form fails
   immediately with `flag provided but not defined: -config`, which took down every Windows base
   build (first failure: `[20:15:16] 03-containerd:` in the Packer log). §7 above had already
   written the *correct* order in prose; the bug was only in the code, not in the design, but
   nothing had executed that line before Scenario A did.
2. **`$ErrorActionPreference = 'Stop'` + `2>&1` on a native command throws on stderr alone,
   independent of exit code, and only on Windows PowerShell 5.1, not pwsh.** containerd always
   logs a harmless one-line notice to stderr on `config dump` against our `version = 3` file
   ("Configuration migrated from version 3, use `containerd config migrate` to avoid migration";
   expected per §7, 2.3's native schema is v4). Merging that into the captured output via `2>&1`
   while the script has `$ErrorActionPreference = 'Stop'` (set at the top of every provisioner
   script in this repo) promotes that single stderr line to a terminating `NativeCommandError`,
   regardless of `$LASTEXITCODE` (confirmed 0 in isolation). Reproduced with
   `powershell.exe -File test.ps1` on the build host; **did not reproduce under `pwsh`**, which is
   why the §7 offline check passed. Fix: drop to `$ErrorActionPreference = 'Continue'` for just the
   `config dump` call, capture `$LASTEXITCODE` immediately after, restore the preference, then
   check the saved exit code explicitly.

**Lesson for future offline validation of provisioner-script snippets in this repo:** run them
through `powershell.exe` (Windows PowerShell 5.1), not `pwsh`; the two have materially different
native-command error semantics, and every Packer `powershell` provisioner here runs 5.1. A pwsh-only
offline check can pass while the actual provisioner script fails identically every time.

Both bugs were caught by running the real Scenario A build (not by broader test coverage; neither
is the kind of thing Pester's static checks catch), fixed, and re-verified offline against the real
v2.3.7 Windows binary under `powershell.exe` before re-running the build. Both fixes are folded
into the containerd-migration commit (`03-containerd.ps1`) rather than kept as separate fix-up
commits, since they landed before that commit was ever shared.

After those two fixes, the Windows base build succeeded (containerd 2.3.7 running, config-dump
assertion passed) and the cluster bootstrapped. Phase 7's Windows-node join timed out waiting for
`kubelet Running`; diagnosis via a direct `New-PSSession -VMName` into the node found `containerd`
Running but `kubelet` Stopped, with a System-log `7034` ("terminated unexpectedly") at the same
timestamp as the pre-reboot `Start-Service` call in `k8s-firstboot.ps1`, almost certainly
`Restart-Computer` killing the process mid-start rather than a real crash, compounded by `New-Service`
registering `kubelet` with no failure-recovery action, so `Automatic` startup never retried it after
the reboot. A manual `Start-Service kubelet` on the node brought it up immediately and cleanly.
Resuming `Main.ps1` from Phase 8 (skipping the non-idempotent Windows-node join in Phase 7, which
has no "already joined" check unlike the Linux-worker path) reached **Scenario A: 33/33 PASS**,
confirming containerd 2.3.7 + kubelet v1.36.5 + k3s v1.36.5+k3s1 work together correctly end-to-end,
including the Windows pause-pod scheduling check against `registry.k8s.io/pause:3.10.2`.

This also surfaced an unrelated, pre-existing infrastructure bug, independently confirmed and
written up in `AGENTS.md` (the "Update 2026-10-24" note alongside the existing WS2022 fwlink entry):
the WS2025 eval ISO fwlink now serves Windows Server **2022** media (confirmed byte-identical via
MD5 to a known WS2022 ISO after a fresh download), so the node validated above is a WS2022 node
under a `win2025-base` label, not actually WS2025. `Test-WindowsIsoValid` does not catch this; it
only checks the ISO mounts and enumerates, not which OS the enumerated images report. There is
currently no scriptable way to obtain a genuine WS2025 ISO; by user decision this is accepted as a
documented, separate blocker rather than something this round fixes, since the dependency bump
itself is what needed validating and it passed.

## 8. Explicitly out of scope / deferred
- k3s 1.37 — waits for Cilium 1.21.
- WS2022 — eval ISO blocker unchanged.
- Helm/Packer/kubectl host versions — unpinned winget installs; only the skew warning is added.
- Genuinely WS2025 validation: the WS2025 fwlink currently serves WS2022 media (see §7a); Scenario
  A's 33/33 PASS validates the dependency bump on WS2022 content under the `win2025-base` label.
  Revisit once Microsoft fixes the fwlink or a WS2025 ISO is sourced out-of-band.
- Hardening the kubelet Windows service with failure-recovery actions so `Automatic` startup
  survives a crash without a reboot, observed in §7a and recurred once more during the Ubuntu
  26.04 stretch (§5, Scenario A), both times self-resolved with a manual `Start-Service kubelet`
  and no rebuild needed. Still outside this round's scope, but no longer a one-off.
