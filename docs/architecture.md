# Architecture — Hyper-V k3s Cluster (Multi-Node, Multi-CNI Edition)

A fully automated, configurable k3s cluster running on a single Windows 11 host via Hyper-V.
All VMs are derived from Packer-built golden base images using differencing disks,
enabling fast node provisioning and reproducible rebuilds.

---

## Table of Contents

1. [Physical Layout](#1-physical-layout)
2. [How Golden Images Are Produced](#2-how-golden-images-are-produced)
3. [How Nodes Are Created from Golden Images](#3-how-nodes-are-created-from-golden-images)
4. [How Node Identities Are Injected](#4-how-node-identities-are-injected)
5. [How Workers Join the Cluster](#5-how-workers-join-the-cluster)
6. [Scenario Comparison — A, B, C, D](#6-scenario-comparison--a-b-c-d)
7. [Service Mesh Considerations](#7-service-mesh-considerations)
8. [CNI Deep Dive](#8-cni-deep-dive)
9. [Node Roles and Installed Components](#9-node-roles-and-installed-components)
10. [Phase Map](#10-phase-map)
11. [Output Files](#11-output-files)

---

## 1. Physical Layout

```
Windows 11 Host (Hyper-V)
│
├── Golden base VHDXs (read-only after Packer build)
│   ├── vhdx/linux-base/                — Ubuntu 24.04 LTS + k3s binary
│   ├── vhdx/win2022-base/              — WS2022 + containerd v1.7.32 + kubelet
│   └── vhdx/win2025-base/              — WS2025 + containerd v1.7.32 + kubelet
│
└── Node VMs (child differencing disks — vhdx/nodes/)
    ├── k8s-cp-01    (Linux control plane — k3s server)
    ├── k8s-lnx-01   (Linux worker — k3s agent)
    ├── k8s-lnx-02   (additional Linux workers, if configured)
    └── k8s-win-01   (Windows worker — upstream kubelet + kube-proxy)  [Scenario A only]

External Hyper-V vSwitch: k8s-external
    — bridges all VMs + host onto the same physical NIC
    — all nodes get DHCP IPs from the router (same L2 segment)
    — host can SSH/WinRM into any VM directly

Pod CIDR     : 10.42.0.0/16   (each node gets a /24 slice)
Service CIDR : 10.43.0.0/16
CoreDNS      : 10.43.0.10
```

The host NIC is auto-detected by finding the interface used for the default route
(`$script:HostNicName` in `config/variables.ps1` can override this).

---

## 2. How Golden Images Are Produced

Golden images are built **once** by Packer and then set read-only. They contain the OS,
all runtime binaries, and configuration that is identical across every node of that type.
Per-node identity (hostname, SSH key, kubeconfig) is injected later — never baked into the base.

### 2.1 Packer overview

Packer uses the `hyperv-iso` builder (`github.com/hashicorp/hyperv >= 1.1.3`) on both
Linux and Windows images. The builder:

1. Creates a temporary Hyper-V VM with the configured CPU/RAM/disk and the ISO mounted.
2. Boots the ISO and types a **boot command** into the VM console to trigger unattended install.
3. Waits for the OS to come up and for a remote management channel to become available.
4. Runs **provisioner scripts** inside the VM over that channel.
5. Shuts down the VM and exports the VHDX.

The resulting VHDX is copied to `vhdx/linux-base/` or `vhdx/win*-base/` and marked read-only.

All Packer `-var` arguments are passed by the PowerShell build scripts (`Build-LinuxBase.ps1`,
`Build-WindowsBase.ps1`), which read values from `config/variables.ps1`. This keeps versions
and credentials in one place.

---

### 2.2 Linux base image (`packer/linux/ubuntu.pkr.hcl`)

**Goal:** Ubuntu 24.04 LTS with the k3s binary pre-installed and cloud-init pre-cleaned so
every cloned VM treats its first boot as a fresh instance.

#### Boot sequence

```
1. Packer mounts Ubuntu 24.04 ISO in a Hyper-V Generation 2 VM
2. Boot command navigates GRUB → adds kernel args pointing to the autoinstall URL:
       autoinstall ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/
3. Packer's built-in HTTP server serves packer/linux/http/user-data (cloud-init autoinstall)
   and packer/linux/http/meta-data
4. Ubuntu cloud-init autoinstall runs unattended:
       - creates admin user (k8sadmin) with sudo
       - injects SSH public key from output/linux-build-key.pub
       - installs base packages, sets locale/timezone
5. VM reboots into the installed OS
6. Packer connects via SSH using output/linux-build-key (ed25519)
```

**SSH key management:** Before invoking Packer, `Build-LinuxBase.ps1` generates a temporary
ed25519 key pair at `output/linux-build-key` / `output/linux-build-key.pub` if they do not
already exist. The public key is regex-patched into `packer/linux/http/user-data` (replacing
any line matching `ssh-ed25519 … packer-linux-build`). Packer then authenticates with the
private key. The same key pair is reused for SSH management of all Linux node VMs.

> **Rebuild note:** If you delete `output/linux-build-key*`, the next run generates a new
> pair and automatically patches user-data. Packer will use the new key; the old base VHDX
> becomes inaccessible via SSH (but nodes derived from it are unaffected since each clone
> gets its own seed ISO with the current key).

#### Provisioner scripts (run over SSH)

| Script | What it does |
|--------|-------------|
| `packer/linux/scripts/01-base.sh` | `apt-get upgrade`, kernel modules (`overlay`, `br_netfilter`), sysctl tuning (`net.ipv4.ip_forward`, `net.bridge.bridge-nf-call-iptables`), disable swap, install `curl`, `socat`, `conntrack`, `nfs-common`, `open-iscsi` |
| `packer/linux/scripts/02-install-k3s-binary.sh` | Downloads the k3s binary from `github.com/k3s-io/k3s/releases` at the pinned version, installs to `/usr/local/bin/k3s`, sets `chmod +x`. **No systemd unit is created** — the unit is written at cluster-bootstrap time so the node-token and server address can be injected. |
| `packer/linux/scripts/03-cloud-init-clean.sh` | Runs `cloud-init clean --logs --seed` and truncates `/etc/machine-id`. This resets cloud-init state so the next boot (as a clone) is treated as the first boot, causing cloud-init to apply the per-node seed ISO. |

After provisioning, Packer shuts down the VM and exports the VHDX to `vhdx/linux-base/`.

---

### 2.3 Windows base image (`packer/windows/winserver.pkr.hcl`)

**Goal:** Windows Server (2022 or 2025) with containerd, upstream Kubernetes binaries,
and a first-boot scheduled task that reads a per-node JSON config and self-configures.

The same Packer template handles both WS2022 and WS2025 via an `os_version` variable.

#### Boot sequence

```
1. Packer mounts the Windows Server evaluation ISO in a Hyper-V Generation 2 VM
2. autounattend.xml is delivered via a virtual floppy disk (floppy_dirs in HCL)
   — the floppy is mounted as drive A:
   — Windows Setup detects autounattend.xml on drive A: and runs fully unattended
3. autounattend.xml:
       - selects correct edition (Standard Desktop for 2022, same for 2025)
       - sets Administrator password
       - runs A:\winrm-setup.ps1 in FirstLogonCommands to enable WinRM
4. Packer connects via WinRM (HTTP, port 5985) using Administrator credentials
5. Provisioner scripts run over WinRM
```

Unlike Linux, Windows does not have a built-in mechanism for serving autoinstall over HTTP.
Packer uses the floppy approach: the entire `packer/windows/autounattend/<version>/` directory
is injected as a virtual floppy. WinRM is enabled inside `winrm-setup.ps1` (runs via
`FirstLogonCommands` in autounattend) and Packer waits for port 5985 to become reachable.

#### Provisioner scripts (run over WinRM)

| Script | What it does |
|--------|-------------|
| `packer/windows/scripts/04-install-k8s-binaries.ps1` | Downloads and installs: `containerd.exe` (v1.7.32, pinned), `kubelet.exe`, `kube-proxy.exe`, `kubectl.exe` (all at the k8s version), `flanneld.exe`, `win-bridge.exe`, `win-overlay.exe`, `host-local.exe`, `hns.psm1`. Configures containerd `config.toml`, registers the containerd Windows service. Creates `C:\k\`, `C:\k\cni\`, `C:\k\cni\config\` directories. Writes `C:\k\net-conf.json` for flannel. Writes static kubeconfig path stubs. |
| `packer/windows/scripts/05-firstboot-setup.ps1` | Writes `C:\k8s-firstboot.ps1` — a PowerShell script that reads `C:\k8s-node-config.json` (injected offline by `Join-Nodes.ps1`), writes actual kubeconfigs and `C:\k\cni\config\cni.conf`, renames the computer, and registers `kubelet` + `kube-proxy` as Windows services. Also creates a `k8s-firstboot` scheduled task (SYSTEM, AtStartup, Trigger=Boot) that runs `k8s-firstboot.ps1` once, logs to `C:\k8s-firstboot-log.txt`, then deletes itself. |

After provisioning, Packer shuts down and the VHDX lands in `vhdx/win2022-base/` or
`vhdx/win2025-base/`.

> **containerd v1.7.32 pin:** v2.x removed the CRI v1 gRPC API (`runtime.v1.RuntimeService`)
> that kubelet v1.32 expects. v1.7.32 is the latest v1.x release and is explicitly set in
> `config/variables.ps1` as `$script:ContainerdVersion = '1.7.32'`.

---

## 3. How Nodes Are Created from Golden Images

`New-LinuxNodes.ps1` (Phase 4) and `New-WindowsNodes.ps1` (Phase 5) create per-node VMs
using **Hyper-V differencing disks**.

### Differencing disk model

```
vhdx/linux-base/disk.vhdx       ← parent (read-only, ~8 GB, never modified)
         │
         ├── vhdx/nodes/k8s-cp-01.vhdx   ← child (~few MB initially, grows with writes)
         ├── vhdx/nodes/k8s-lnx-01.vhdx
         └── vhdx/nodes/k8s-lnx-02.vhdx
```

A child disk stores **only the delta** relative to the parent. Writes from the VM go to the
child; reads are transparently served from the parent if the block hasn't been written.
Creating a child disk is near-instantaneous regardless of parent size.

**Benefits:**
- Node creation takes seconds, not minutes
- Multiple nodes share the base without duplication on disk
- Destroying a node = delete its child VHDX (parent unaffected)
- The parent cannot be corrupted by a running VM (Hyper-V enforces read-only at the
  block-device level)
- Changing k3s version or base OS only requires rebuilding the golden image once

**Trade-off:** All child disks on a host share the same parent. The parent must not be
modified or moved while any child is attached. Relocating the golden image requires
re-pointing all child disks (`Set-VHD -ParentPath`).

For each node, `New-LinuxNodes.ps1` calls the `New-DifferencingNode` helper:

```powershell
New-VHD -Path $childPath -ParentPath $parentPath -Differencing
New-VM   -Name $NodeName -Generation 2 -VHDPath $childPath -SwitchName $vSwitchName
Set-VM   -Name $NodeName -ProcessorCount $CPU -MemoryStartupBytes ($RAM * 1MB)
Set-VMFirmware -VMName $NodeName -EnableSecureBoot Off
```

The VM is then given a cloud-init seed ISO (Linux) or left for offline config injection (Windows).

---

## 4. How Node Identities Are Injected

Each VM starts life as an identical clone of the base image. Identity is injected differently
for Linux and Windows.

### 4.1 Linux — cloud-init NoCloud seed ISO

`New-LinuxNodes.ps1` creates a per-node seed ISO using **oscdimg.exe** (from Windows ADK):

```
Seed ISO (volume label: CIDATA)
├── meta-data     — instance-id: <NodeName>
│                   local-hostname: <NodeName>
└── user-data     — #cloud-config
                    hostname: <NodeName>
                    users:
                      - name: k8sadmin
                        ssh_authorized_keys: [<management public key>]
                        sudo: ALL=(ALL) NOPASSWD:ALL
```

The ISO is mounted as a DVD drive on the VM. Because `03-cloud-init-clean.sh` reset
cloud-init's state in the base image, the first boot of each clone triggers a fresh
cloud-init run. Cloud-init discovers the `CIDATA` ISO via the NoCloud datasource,
applies the user-data, and cloud-init marks itself complete.

Result: the VM boots with the correct hostname and SSH key, ready for Phase 6/7 SSH commands.

### 4.2 Windows — offline VHD config injection

Windows cannot run cloud-init. Instead, `Join-Nodes.ps1` injects a JSON configuration file
**into the VHDX while the VM is powered off**:

```powershell
Mount-VHD -Path $childVhdxPath -ReadWrite
# find the drive letter that appeared
$driveLetter = (Get-Disk | ... | Get-Partition | Get-Volume).DriveLetter

$config = @{
    NodeName      = $NodeName
    K3sServerUrl  = "https://$cpIp:6443"
    NodeToken     = $token
    ClusterCidr   = $script:ClusterCidr
    ServiceCidr   = $script:ServiceCidr
    ClusterDnsIp  = $script:ClusterDnsIp
    AdminKubeconfig   = (Get-Content $AdminKcPath -Raw)
    FlannelKubeconfig = (Get-Content $FlannelKcPath -Raw)
}
$config | ConvertTo-Json | Set-Content "${driveLetter}:\k8s-node-config.json"

Dismount-VHD -Path $childVhdxPath
```

On first boot, the Windows scheduled task runs `C:\k8s-firstboot.ps1`:
1. Reads `C:\k8s-node-config.json`
2. Writes kubeconfigs to `C:\k\`, writes flannel CNI config
3. Registers `kubelet` and `kube-proxy` as Windows services with correct flags
4. Renames the computer to match `NodeName`
5. **Reboots** (computer rename requires reboot on Windows)
6. On second boot, `kubelet` starts automatically, registers with the API server, and
   the node becomes Ready

`Join-Nodes.ps1` detects the rename-reboot via a VMBus PSSession retry loop and waits
for the second boot before checking node status.

---

## 5. How Workers Join the Cluster

### Linux workers (SSH)

`Join-Nodes.ps1` SSHs into each Linux worker and runs:

```bash
INSTALL_K3S_SKIP_DOWNLOAD=true \
K3S_URL=https://<cp-ip>:6443 \
K3S_TOKEN=<node-token> \
k3s agent --node-name <NodeName>
```

`INSTALL_K3S_SKIP_DOWNLOAD=true` tells the k3s install script to skip downloading the
binary (already present in the base image) and only write the systemd unit. The agent
connects to the API server, receives its pod CIDR slice, and the CNI plugin assigns IPs
to pods from that slice.

### Windows workers (VMBus + scheduled task)

Windows workers do not use SSH. After the VHD injection (§4.2), the VM is started.
`Join-Nodes.ps1` establishes a **Hyper-V Direct (VMBus) PSSession** — a local PowerShell
remoting channel that does not require network connectivity or WinRM certificates:

```powershell
$session = New-PSSession -VMName $NodeName -Credential $cred
```

VMBus remoting is used to:
- Monitor the first-boot task log (`C:\k8s-firstboot-log.txt`)
- Verify the kubelet service reaches `Running` state
- Query node registration via kubectl

This avoids the complexity of setting up WinRM over the network for new nodes.

---

## 6. Scenario Comparison — A, B, C, D

All scenarios use k3s v1.32.5+k3s1 on Ubuntu 24.04 LTS as the control plane and Linux
workers. They differ in CNI plugin, Windows node support, and networking capabilities.

---

### Scenario A — Flannel (embedded) + Windows worker

**Script:** `Run-ScenarioA.ps1` | **Verified:** 18/18 PASS

**Topology:** k8s-cp-01 + k8s-lnx-01 + k8s-win-01 (WS2022)

**How it works:**

k3s ships with Flannel embedded. On Linux nodes Flannel runs as a k3s sub-process and
manages the Linux routing table (`host-gw` backend = one OS route per node, no tunnelling).
On the Windows worker, `flanneld.exe` is pre-installed in the base image; it reads the
k3s API to discover node CIDRs and programs Windows HNS rules via `win-bridge.exe`.

```
Networking:
  Linux pods  ←→  host-gw routing  ←→  Windows pods
  All on same L2 segment (k8s-external vSwitch)
  No VXLAN: packets travel at native L2 speed
```

**Advantages:**
- Simplest possible setup — Flannel is embedded, zero extra install steps
- Windows worker support: only `'flannel'` mode is compatible with Windows nodes
- `host-gw` avoids VXLAN overhead; latency and throughput are near-native
- Broadest compatibility — works on any Hyper-V host without special kernel features

**Disadvantages:**
- No network policy enforcement — any pod can reach any other pod
- No encryption of pod-to-pod traffic
- No L7 visibility or observability (no eBPF, no metrics per flow)
- Flannel does not support IPv6 dual-stack
- Scaling beyond a single L2 segment would require switching to VXLAN backend
  (which breaks Windows compatibility)

**When to choose:** Mixed Windows/Linux workloads; maximum compatibility; simple
development or CI environments where policy enforcement is not required.

---

### Scenario B — Multus (meta-CNI on top of Flannel)

**Script:** `Run-ScenarioB.ps1` | **Verified:** 14/14 PASS

**Topology:** k8s-cp-01 + k8s-lnx-01 (Linux-only)

**How it works:**

Multus does not replace Flannel. It is a **meta-CNI** that acts as a broker:
it calls the default CNI (Flannel) to set up the primary pod interface (`eth0`),
and can additionally call secondary CNI plugins to attach extra interfaces (`net1`, `net2`, …).
Secondary interfaces are defined via `NetworkAttachmentDefinition` (NAD) custom resources.

```yaml
# Example NAD for a secondary macvlan interface
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-conf
spec:
  config: '{ "type": "macvlan", "master": "eth0", "mode": "bridge", "ipam": {...} }'
```

Pods opt in by adding an annotation:
```yaml
annotations:
  k8s.v1.cni.cncf.io/networks: macvlan-conf
```

Multus is installed via `config/cni/multus-daemonset.yaml` (thick plugin image).

**Advantages:**
- Enables multi-homed pods (multiple network interfaces per pod)
- Required for telco/NFV workloads (SRIOV, DPDK, secondary VLANs)
- Non-destructive: Flannel remains the default CNI; existing workloads are unaffected
- Adds the NAD CRD which is a building block for many CNI chaining scenarios

**Disadvantages:**
- Still inherits all Flannel limitations (no policy, no encryption, no observability)
- Complexity: operators must manage NAD resources per namespace/workload
- No Windows worker support (Multus Linux DaemonSet pods cannot run on Windows)
- Secondary CNI plugins must be manually installed and configured per node
- No built-in IPAM for secondary interfaces beyond what the secondary CNI provides

**When to choose:** Workloads that need multiple network interfaces (e.g., separating
management traffic from data-plane traffic); NFV or telco scenarios; environments
that need pod network isolation at the L2/VLAN level without replacing the primary CNI.

---

### Scenario C — Cilium (full CNI replacement)

**Script:** `Run-ScenarioC.ps1` | **Verified:** 13/13 PASS

**Topology:** k8s-cp-01 + k8s-lnx-01 (Linux-only)

**How it works:**

Cilium completely replaces Flannel. k3s is started with:
```
--flannel-backend=none --disable-network-policy
```
This tells k3s not to start its embedded flannel process and not to deploy its built-in
network policy controller (Cilium provides its own).

Cilium is installed via Helm (`cilium/cilium` chart v1.19.4) before workers join
(pre-join phase ordering, §10). It uses eBPF programs loaded into the Linux kernel
to implement routing, load balancing, and network policy — entirely in kernel space,
without iptables chains.

Configuration (`config/cni/cilium-values.yaml`):
```yaml
kubeProxyReplacement: false      # keep kube-proxy for compatibility
routingMode: native              # direct L2 routing (like host-gw, no VXLAN)
ipv4NativeRoutingCIDR: 10.42.0.0/16
autoDirectNodeRoutes: true       # auto-install node routes
ipam:
  mode: kubernetes               # use k3s-assigned pod CIDRs
# Custom CNI binary/config paths for k3s (different from standard kubelet)
cni:
  binPath: /var/lib/rancher/k3s/data/current/bin
  confPath: /var/lib/rancher/k3s/agent/etc/cni/net.d
```

**Advantages:**
- **eBPF-based**: high-performance kernel-space packet processing; lower latency
  than iptables for services (especially at scale)
- **Full NetworkPolicy support** (standard k8s) plus **CiliumNetworkPolicy** (L7 HTTP/gRPC rules)
- **Transparent encryption**: WireGuard or IPsec between nodes, zero application changes
- **Rich observability**: Hubble (built-in), provides per-flow metrics, DNS visibility,
  service dependency graphs
- **Built-in load balancing** via eBPF (can replace kube-proxy entirely with
  `kubeProxyReplacement: true`)
- **Service mesh capabilities without a sidecar** (see §7)

**Disadvantages:**
- Requires Linux kernel ≥ 4.19 (eBPF co-routine support); Ubuntu 24.04 ships 6.8 ✓
- No Windows worker support — Cilium's eBPF datapath is Linux-only
- More complex to debug than Flannel (eBPF programs, Cilium-specific CLI `cilium`)
- Helm + Cilium operator pod overhead (small, but non-zero)
- `routingMode: native` requires all nodes to be on the same L2 segment
  (which matches this Hyper-V setup); VXLAN mode would be needed across L3 boundaries

**When to choose:** Security-conscious environments that need NetworkPolicy; observability
requirements; environments targeting eventual service mesh adoption; Linux-only clusters
where Flannel's limitations are a bottleneck.

---

### Scenario D — Calico (full CNI replacement via tigera-operator)

**Script:** `Run-ScenarioD.ps1` | **Verified:** 13/13 PASS

**Topology:** k8s-cp-01 + k8s-lnx-01 (Linux-only)

**How it works:**

Calico also completely replaces Flannel. k3s flags are identical to Cilium
(`--flannel-backend=none --disable-network-policy`). Calico is installed via the
`tigera-operator` Helm chart which deploys a Kubernetes operator; the operator reads
an `Installation` CR to configure the Calico data plane.

Configuration (`config/cni/calico-values.yaml`):
```yaml
installation:
  cni:
    type: Calico
  calicoNetwork:
    ipPools:
      - cidr: 10.42.0.0/16
        encapsulation: VXLAN      # safe across Hyper-V VMs; BGP not needed on flat L2
        natOutgoing: Enabled
        nodeSelector: all()
    bgp: Disabled
```

VXLAN is used (rather than BGP peer routing) because Hyper-V VMs on the same vSwitch
already share an L2 segment — BGP would be unnecessary complexity. The tigera-operator
runs in the `tigera-operator` namespace; Calico pods run in `calico-system`.

**Advantages:**
- **Mature NetworkPolicy** implementation — Calico's policy engine is one of the oldest
  and most battle-tested in the ecosystem
- **GlobalNetworkPolicy**: cluster-wide deny/allow rules that span namespaces
  (not available in standard Kubernetes NetworkPolicy)
- **HostEndpoint policy**: can enforce policy on the host network interface itself,
  not just pod interfaces
- **eBPF data plane option**: Calico can switch its data plane from iptables to eBPF
  (`spec.calicoNetwork.linuxDataplane: BPF` in the Installation CR)
- **WireGuard encryption** (same as Cilium): node-to-node traffic encrypted transparently
- **BGP peering** for production on-premises deployments: Calico can peer with physical
  routers and advertise pod CIDRs without any overlay (not used here, but available)

**Disadvantages:**
- The tigera-operator adds a layer of indirection: config goes into CRs, not Helm values
  directly; debugging requires inspecting `Installation`, `FelixConfiguration`, and `IPPool` CRs
- Slower startup than Cilium: operator must reconcile CRs before Calico pods run
- No built-in equivalent of Hubble (Cilium's flow observability); Calico requires a
  separate tool (e.g. Calico Enterprise or third-party) for L7 visibility
- VXLAN encapsulation adds overhead vs native routing (mitigated by `routingMode: native`
  which Cilium uses by default in this setup)
- No Windows worker support in this configuration

**When to choose:** Environments already familiar with Calico policy model; on-premises
deployments that need BGP peering with routers; teams that prefer an operator-managed
lifecycle; workloads that need GlobalNetworkPolicy or HostEndpoint policy.

---

### Scenario Summary Table

| Capability | A (Flannel) | B (Multus) | C (Cilium) | D (Calico) |
|-----------|:-----------:|:-----------:|:-----------:|:-----------:|
| Windows workers | ✅ | ❌ | ❌ | ❌ |
| Multi-homed pods | ❌ | ✅ | ❌† | ❌† |
| NetworkPolicy (L3/L4) | ❌ | ❌ | ✅ | ✅ |
| L7 NetworkPolicy (HTTP/gRPC) | ❌ | ❌ | ✅ | ❌ |
| GlobalNetworkPolicy | ❌ | ❌ | ✅‡ | ✅ |
| HostEndpoint policy | ❌ | ❌ | ✅ | ✅ |
| Pod-to-pod encryption | ❌ | ❌ | ✅ (WG/IPsec) | ✅ (WG) |
| eBPF data plane | ❌ | ❌ | ✅ | optional |
| kube-proxy replacement | ❌ | ❌ | optional | ❌ |
| Flow observability | ❌ | ❌ | ✅ (Hubble) | ❌ |
| BGP peering | ❌ | ❌ | ❌ | ✅ |
| Service mesh (sidecar) | add-on | add-on | sidecar-free | add-on |
| Overlay protocol | none (L2) | none (L2) | none (L2)§ | VXLAN |
| Operational complexity | low | medium | medium-high | medium-high |

† Cilium and Calico can be combined with Multus for multi-homed pods, but that is not
  configured in these scenarios.
‡ Cilium calls these `CiliumClusterwideNetworkPolicy`.
§ Native routing is configured (`routingMode: native`); VXLAN mode is also supported.

---

## 7. Service Mesh Considerations

A service mesh adds capabilities beyond what a CNI provides:
- **mTLS between services** (zero-trust, without app changes)
- **Traffic management** (retries, timeouts, circuit breakers, canary routing)
- **L7 observability** (traces, request rates, error rates per service pair)
- **Ingress/egress gateway** control

### Scenario A (Flannel) — service mesh possible, sidecar required

Flannel has no service mesh capabilities. Adding a service mesh requires deploying a
sidecar-proxy-based solution:

| Option | Approach | Notes |
|--------|---------|-------|
| **Istio** | Envoy sidecar injected per pod | Most feature-complete; heavy (Envoy + istiod); not recommended for this lab scale |
| **Linkerd** | Rust-based lightweight sidecar | Lighter than Istio; easier to operate; recommended if a sidecar mesh is needed on Flannel |
| **Consul Connect** | Envoy sidecar + Consul control plane | Good if you already use Consul for service discovery |

**Windows limitation:** Linkerd and Istio sidecars do **not** support Windows containers.
A Flannel+Windows cluster cannot have uniform mTLS across all pods. Linux pods could be
meshed while Windows pods remain unmeshed — a security boundary that must be explicitly
considered.

**Verdict:** Possible on Linux pods. Not feasible for Windows pods. Choose Linkerd for
minimal overhead.

---

### Scenario B (Multus) — same as Scenario A for service mesh

Multus does not add service mesh capabilities. A sidecar mesh can be layered on top —
exactly as with Flannel. The same Windows limitation applies.

Additionally, sidecar proxies only intercept the **primary interface** (`eth0`). Traffic
on secondary Multus interfaces (`net1`, etc.) is invisible to the mesh. If secondary
interface traffic also needs mTLS, it must be handled at the application layer.

**Verdict:** Possible on primary interface. Secondary interfaces are outside the mesh.

---

### Scenario C (Cilium) — service mesh without sidecars

Cilium v1.12+ includes **Cilium Service Mesh**, which can provide mTLS and L7 traffic
management **without injecting any sidecar proxy**. The implementation uses eBPF to
intercept traffic at the kernel level.

Two modes are available:

| Mode | How it works | This cluster |
|------|-------------|-------------|
| **Sidecar-free** (Envoy via DaemonSet) | One Envoy proxy per node (not per pod); Cilium routes traffic through it for L7 inspection | Supported — add `envoy.enabled: true` to `cilium-values.yaml` |
| **Sidecar** (Istio + Cilium mesh) | Cilium handles CNI; Istio handles sidecar injection; they are aware of each other | Possible with `--set cni.exclusive=false` on Istio install |

Enabling sidecar-free L7 in this cluster:
```yaml
# config/cni/cilium-values.yaml additions
envoy:
  enabled: true
ingressController:
  enabled: true
  loadbalancerMode: shared
```

This provides HTTP retries, request routing, and mTLS with zero pod changes.
Hubble then shows per-request metrics.

**Verdict:** Best service mesh option in this repo. Sidecar-free mesh is natively
supported and is the most operationally lightweight approach. Recommended if service
mesh capabilities are needed.

---

### Scenario D (Calico) — service mesh via add-on

Calico does not include built-in service mesh features. Options:

| Option | Notes |
|--------|-------|
| **Istio** | Standard Istio works alongside Calico. Calico handles CNI; Istio injects sidecars. No conflicts. Most common production pairing. |
| **Linkerd** | Works alongside Calico. Lightweight sidecar. |
| **Calico Enterprise** | Tigera's commercial offering adds L7 visibility and policy, but is not free. |

Istio + Calico is a well-documented combination in production environments. Calico
enforces network policy at the CNI layer (L3/L4); Istio enforces it at the application
layer (L7 mTLS). They are complementary.

**Verdict:** Possible with any sidecar mesh. No native sidecar-free option (unlike Cilium).
Istio is the most common choice and has the broadest documentation for Calico + Istio.

---

## 8. CNI Deep Dive

### 8.1 Flannel host-gw

```
Pod CIDR     : 10.42.0.0/16
Service CIDR : 10.43.0.0/16

Node CIDRs (assigned by k3s):
  k8s-cp-01   → 10.42.0.0/24
  k8s-lnx-01  → 10.42.1.0/24
  k8s-win-01  → 10.42.2.0/24

Linux routing table (per node, managed by flannel):
  10.42.1.0/24  via <k8s-lnx-01 IP>  dev eth0
  10.42.2.0/24  via <k8s-win-01 IP>  dev eth0

Windows routing table (written by start-network.ps1 on first boot):
  10.42.0.0/24  via <k8s-cp-01 IP>
  10.42.1.0/24  via <k8s-lnx-01 IP>
```

`host-gw` is mandatory for Windows — Windows flannel cannot create VXLAN tunnels.
It also requires all nodes to be on the same L2 broadcast domain (satisfied by the
shared `k8s-external` vSwitch).

### 8.2 Multus chaining

```
kubelet → calls Multus CNI binary
             │
             ├── calls Flannel (default delegate) → creates eth0, assigns 10.42.x.y/32
             └── calls secondary delegates (per NAD annotation)
                     → creates net1, net2, …
```

Multus reads the pod annotation `k8s.v1.cni.cncf.io/networks`, resolves each name to
a NAD in the pod's namespace, and calls the CNI plugin specified in the NAD config.

### 8.3 Cilium data plane

```
Pod A (10.42.0.5) → kernel socket → eBPF hook (tc ingress/egress)
    → policy check (eBPF map lookup) → BPF SNAT/routing
    → physical NIC → router → Pod B node NIC
    → eBPF hook → policy check → deliver to Pod B socket
```

The eBPF hook is attached at the Linux Traffic Control (tc) layer — after the NIC driver
but before the network stack. This lets Cilium intercept, inspect, and drop/forward packets
without going through iptables. Hubble taps the same hook to emit flow records.

### 8.4 Calico data plane (iptables mode, as configured here)

```
Pod A → veth pair → Linux bridge / routing table
    → iptables FORWARD chain → Calico chains (cali-FORWARD, cali-to-*, cali-from-*)
    → Felix programs chains based on NetworkPolicy + IPPool CRs
    → VXLAN encapsulation (VTEP on each node) → Pod B node
    → VXLAN decap → iptables → deliver to Pod B
```

Felix (the Calico node agent, running as part of `calico-node` DaemonSet) watches
Kubernetes and Calico CRs and translates them into iptables rules. The tigera-operator
manages Felix configuration via the `FelixConfiguration` CR.

---

## 9. Node Roles and Installed Components

### Linux control plane — `k8s-cp-01`

| Component | Version | Notes |
|-----------|---------|-------|
| k3s | v1.32.5+k3s1 | API server, scheduler, controller-manager, etcd, kubelet, containerd |
| containerd | 2.0.5-k3s1.32 | Bundled with k3s; manages Linux pod containers |
| Flannel | embedded | host-gw (Scenarios A, B); disabled for C, D |
| CoreDNS | embedded | ClusterIP `10.43.0.10` |
| local-path-provisioner | embedded | Default StorageClass |

For Scenarios C and D, k3s starts with `--flannel-backend=none --disable-network-policy`.

### Linux workers — `k8s-lnx-NN`

Run `k3s agent`. The k3s binary is pre-installed in the base image; the systemd unit
is written by `Join-Nodes.ps1` via SSH. Same containerd version as the CP.

### Windows workers — `k8s-win-NN` (Scenario A only)

Does **not** run k3s. Uses upstream Kubernetes binaries.

#### Installed binaries (`C:\k\`)

| Binary | Version | Role |
|--------|---------|------|
| `kubelet.exe` | v1.32.5 | Node agent; registers with k3s API server |
| `kube-proxy.exe` | v1.32.5 | kernelspace mode; programs HNS rules |
| `kubectl.exe` | v1.32.5 | Used by `start-network.ps1` to query pod CIDR |
| `containerd.exe` | **v1.7.32** (pinned) | Container runtime |

#### CNI plugins (`C:\k\cni\`)

| Plugin | Source | Role |
|--------|--------|------|
| `flannel.exe` | flannel v0.25.7 | CNI broker; reads flannel net-conf, delegates to win-bridge |
| `win-bridge.exe` | ms/windows-container-networking v0.3.0 | Creates HNS L2Bridge endpoints |
| `host-local.exe` | containernetworking/plugins | IPAM — allocates pod IPs from node CIDR |
| `hns.psm1` | microsoft/SDN | PowerShell HNS helper module |

---

## 10. Phase Map

| Phase | Script | Sentinel | Notes |
|-------|--------|----------|-------|
| 0 | `Install-Prerequisites.ps1` | `phase0.done` | Installs tools including Windows ADK (oscdimg) |
| 1 | `New-HyperVSwitch.ps1` | `phase1.done` | Creates `k8s-external` external vSwitch |
| BASE-L | `Build-LinuxBase.ps1` | `linux-base.done` | Packer builds Ubuntu golden VHDX |
| BASE-W | `Build-WindowsBase.ps1` | `win2022-base.done`, `win2025-base.done` | Packer builds Windows golden VHDX(s) |
| 4 | `New-LinuxNodes.ps1` | `node-<name>.done` per node | Differencing disks + seed ISOs + VM start |
| 5 | `New-WindowsNodes.ps1` | `node-<name>.done` per node | Differencing disks + VM created (not started) |
| 6 | `Bootstrap-ControlPlane.ps1` | `cp-bootstrap.done` | k3s server + RBAC + credentials export |
| 7 | `Join-Nodes.ps1` | `node-<name>-ready.done` per node | Linux: SSH agent install; Windows: offline VHD inject + first boot |
| 8 | `Apply-CNI.ps1` | `cni.done` | Flannel: no-op; Multus: kubectl apply; Cilium/Calico: Helm install |
| 9 | `Export-KubeConfig.ps1` | `kubeconfig.done` | Copies + patches kubeconfig from CP VM |
| 10 | `Verify-Cluster.ps1` | `verify.done` | Cross-node ICMP, HTTP, DNS, ClusterIP, CNI health, Windows pod |

**Cilium/Calico phase ordering:** `Main.ps1` detects `CNIPlugin -in @('cilium', 'calico')`
and runs Phase 8 (`Apply-CNI.ps1`) *before* Phase 7 (`Join-Nodes.ps1`) so that nodes have
a working CNI when they join. Without this, nodes would stay `NotReady` indefinitely.

All phases are **idempotent** via sentinel files in `output/sentinels/`. Delete a sentinel
or pass `-ForcePhase N` to `Main.ps1` to re-run a phase.

---

## 11. Output Files

| File | Contents |
|------|----------|
| `output/kubeconfig.yaml` | Admin kubeconfig with CP IP patched in |
| `output/cluster-info.txt` | Node IPs, CIDR summary, kubectl examples |
| `output/node-token.txt` | k3s node join token |
| `output/admin-kubeconfig.yaml` | Kubeconfig retrieved from CP (pre-patch) |
| `output/flannel-kubeconfig.yaml` | Flannel ServiceAccount kubeconfig for Windows workers |
| `output/linux-build-key` | Ed25519 private key for SSH into Linux VMs |
| `output/linux-build-key.pub` | Corresponding public key |
| `output/seed-isos/<name>.iso` | Per-node cloud-init seed ISO |
| `output/sentinels/` | Phase completion marker files |
