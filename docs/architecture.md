# Architecture — Hyper-V k3s Cluster (Multi-Node, Multi-CNI Edition)

A configurable k3s cluster running entirely on a single Windows 11 host via Hyper-V. Supports multiple topology scenarios with different CNI plugins, all built from golden base VHDXs using Packer differencing-disk clones.

---

## Physical Layout

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
    └── k8s-win-01   (Windows worker — upstream kubelet + kube-proxy)  [Scenario A only]
```

All node VMs connect to a single external Hyper-V vSwitch (`k8s-external`) and receive DHCP addresses from the router. All nodes are on the same L2 segment.

---

## Tested Scenarios

| Scenario | Script | CNI | Nodes | Verification |
|----------|--------|-----|-------|-------------|
| A | `Run-ScenarioA.ps1` | Flannel (embedded, host-gw) | k8s-cp-01 + k8s-lnx-01 + k8s-win-01 (WS2022) | 18/18 PASS |
| B | `Run-ScenarioB.ps1` | Multus v4.3.0 on top of Flannel | k8s-cp-01 + k8s-lnx-01 | 14/14 PASS |
| C | `Run-ScenarioC.ps1` | Cilium v1.19.4 (replaces Flannel) | k8s-cp-01 + k8s-lnx-01 | 13/13 PASS |
| D | `Run-ScenarioD.ps1` | Calico v3.29.3 via tigera-operator (replaces Flannel) | k8s-cp-01 + k8s-lnx-01 | 13/13 PASS |

---

## Node Roles

### Linux control plane — `k8s-cp-01`

Runs k3s in server mode. Bundles the full Kubernetes control plane plus an embedded worker (k3s runs a kubelet on the CP node by default).

| Component | Version | Notes |
|-----------|---------|-------|
| k3s | v1.32.5+k3s1 | API server, scheduler, controller-manager, embedded etcd, kubelet, containerd |
| containerd | 2.0.5-k3s1.32 | Bundled with k3s |
| Flannel | embedded | host-gw backend (used for Scenarios A and B) |
| CoreDNS | embedded | ClusterIP `10.43.0.10` |
| local-path-provisioner | embedded | Default StorageClass |

For **Scenarios C and D**, k3s is started with `--flannel-backend=none --disable-network-policy` so that Cilium or Calico fully owns networking.

### Linux workers — `k8s-lnx-01` (and additional workers)

Run k3s in agent mode. Join the cluster via SSH from the host using the node-token exported from the CP.

### Windows worker — `k8s-win-01` (Scenario A only)

Does **not** run k3s. Uses upstream Kubernetes binaries that speak the standard Kubernetes API.

#### Installed binaries (`C:\k\`)

| Binary | Version | Role |
|--------|---------|------|
| `kubelet.exe` | v1.32.5 | Node agent; registers with k3s API server |
| `kube-proxy.exe` | v1.32.5 | kernelspace mode; programs HNS load-balancing rules |
| `kubectl.exe` | v1.32.5 | Used by `start-network.ps1` to query pod CIDR |
| `containerd.exe` | **v1.7.32** (pinned) | Container runtime — see containerd version pin note below |

#### CNI plugins (`C:\k\cni\`)

| Plugin | Source | Role |
|--------|--------|------|
| `flannel.exe` | flannel v0.25.7 | CNI wrapper; delegates to win-bridge |
| `win-bridge.exe` | ms/windows-container-networking v0.3.0 | Creates HNS endpoints for pods |
| `host-local.exe` | containernetworking/plugins | IPAM (assigns pod IPs from node CIDR) |
| `hns.psm1` | microsoft/SDN | PowerShell HNS helpers |

**containerd version pin:** containerd is pinned to **v1.7.32**. v2.x removed the CRI v1 gRPC API (`runtime.v1.RuntimeService`) that kubelet v1.32 requires. Pinned in `config/variables.ps1` as `$script:ContainerdVersion = '1.7.32'`.

---

## CNI Architecture

### Flannel (Scenario A and B baseline)

Embedded in k3s, host-gw backend. Direct L2 routing — no VXLAN tunnelling. Each node's pod CIDR is routed via OS routing table entries.

```
Pod CIDR     : 10.42.0.0/16
Service CIDR : 10.43.0.0/16

Linux routing table entry (managed by embedded flannel):
  10.42.x.0/24  via <worker node IP>

Windows routing table entry (written by start-network.ps1):
  10.42.0.0/24  via <CP/Linux IP>
```

`host-gw` is required for Windows workers — Windows flannel cannot use VXLAN tunnelling.

### Multus (Scenario B)

Multus is a **meta-CNI**: it does not replace Flannel but sits in front of it and enables attaching multiple network interfaces to pods. Applied via `kubectl apply` using `config/cni/multus-daemonset.yaml` (image: `ghcr.io/k8snetworkplumbingwg/multus-cni:v4.3.0-thick`). Registers the `NetworkAttachmentDefinition` CRD.

### Cilium (Scenario C)

Full CNI replacement. k3s flannel is disabled (`--flannel-backend=none --disable-network-policy`). Installed via Helm chart `cilium/cilium` v1.19.4 using `config/cni/cilium-values.yaml`.

Key settings:
```yaml
kubeProxyReplacement: false
routingMode: native
ipv4NativeRoutingCIDR: "10.42.0.0/16"
autoDirectNodeRoutes: true
ipam:
  mode: kubernetes
```

**Phase ordering:** Cilium must be installed *before* workers join (nodes stay `NotReady` without a CNI when `--flannel-backend=none`). `Main.ps1` runs `Apply-CNI.ps1` automatically before `Join-Nodes.ps1` when `CNIPlugin = 'cilium'`.

### Calico (Scenario D)

Full CNI replacement via the tigera-operator Helm chart. k3s flannel is disabled (same as Cilium). Installed via `helm install calico projectcalico/tigera-operator` v3.29.3 using `config/cni/calico-values.yaml`.

Key settings:
```yaml
installation:
  cni:
    type: Calico
  calicoNetwork:
    ipPools:
      - cidr: 10.42.0.0/16
        encapsulation: VXLAN   # safe across Hyper-V VMs; no BGP needed
        natOutgoing: Enabled
    bgp: Disabled
```

Pods run in `calico-system` namespace (label `k8s-app=calico-node`). Operator runs in `tigera-operator` namespace.

**Phase ordering:** Same as Cilium — `Main.ps1` applies Calico before workers join.

---

## Build Process — Golden Images + Differencing Disks

### Why differencing disks?

A golden base VHDX is built once by Packer and set **read-only**. Each node VM gets a child differencing disk (a few MB) created in seconds. This means:
- Rebuilding a node is instant (delete child disk + re-create)
- Multiple nodes share the same base without duplication
- The base cannot be corrupted by a running VM

### Linux base image — Packer sequence

| Step | Script | What it does |
|------|--------|--------------|
| cloud-init | `packer/linux/http/user-data` | Autoinstall Ubuntu; injects ephemeral SSH key |
| 1 | `01-base.sh` | apt packages, kernel modules, sysctl tuning, disable swap |
| 2 | `02-install-k3s-binary.sh` | Downloads k3s binary to `/usr/local/bin/k3s` (no systemd unit yet) |
| 3 | `03-cloud-init-clean.sh` | `cloud-init clean --logs --seed`; truncate machine-id so clones get fresh identity |

### Windows base image — Packer sequence

| Step | Script | What it does |
|------|--------|--------------|
| autounattend | `packer/windows/autounattend/2022/autounattend.xml` | Unattended WS2022 install + WinRM |
| 1 | `01-base.ps1` | ExecutionPolicy, firewall, WinRM hardening |
| 2 | `02-containers.ps1` | Enable Containers + Hyper-V features (triggers reboot) |
| 3 | `03-containerd.ps1` | Install containerd v1.7.32; write `config.toml` |
| 4 | `04-install-k8s-binaries.ps1` | kubelet / kube-proxy / kubectl / CNI plugins; static config (no kubeconfigs yet) |
| 5 | `05-firstboot-setup.ps1` | Write `C:\k8s-firstboot.ps1` template + register AtStartup scheduled task |

### Node creation — per-node steps

**Linux nodes:** `New-LinuxNodes.ps1` creates a child differencing disk, creates a Hyper-V VM, and attaches a per-node seed ISO (`output/seed-isos/<name>.iso`) built with `oscdimg.exe`. The seed ISO (CIDATA volume) injects hostname and SSH public key via cloud-init.

**Windows nodes:** `New-WindowsNodes.ps1` creates a child differencing disk + Hyper-V VM but does **not start** it. `Join-Nodes.ps1` later mounts the VHDX offline (`Mount-VHD`), writes `C:\k8s-node-config.json` (node token, CP IP, hostname), dismounts, then starts the VM. On first boot, `k8s-firstboot.ps1` reads the JSON, writes kubeconfigs, registers kubelet, renames the computer, and reboots.

---

## Phase Map

| Phase | Script | Sentinel | Notes |
|-------|--------|----------|-------|
| 0 | `Install-Prerequisites.ps1` | `phase0.done` | Installs tools including Windows ADK (for oscdimg) |
| 1 | `New-HyperVSwitch.ps1` | `phase1.done` | Creates `k8s-external` external vSwitch |
| BASE-L | `Build-LinuxBase.ps1` | `linux-base.done` | Packer builds Ubuntu golden VHDX |
| BASE-W | `Build-WindowsBase.ps1` | `win2022-base.done`, `win2025-base.done` | Packer builds Windows golden VHDX(s) |
| 4 | `New-LinuxNodes.ps1` | `node-<name>.done` per node | Differencing disks + seed ISOs + VM start |
| 5 | `New-WindowsNodes.ps1` | `node-<name>.done` per node | Differencing disks + VM created (not started) |
| 6 | `Bootstrap-ControlPlane.ps1` | `cp-bootstrap.done` | k3s server + RBAC + flannel credentials |
| 7 | `Join-Nodes.ps1` | `node-<name>-ready.done` per node | Linux: SSH agent install; Windows: offline config inject + first boot |
| 8 | `Apply-CNI.ps1` | `cni.done` | Flannel: no-op; Multus: kubectl apply; Cilium/Calico: Helm install |
| 9 | `Export-KubeConfig.ps1` | `kubeconfig.done` | Copies + patches kubeconfig from CP VM |
| 10 | `Verify-Cluster.ps1` | `verify.done` | Cross-node ICMP, HTTP, DNS, ClusterIP, CNI health, Windows pod |

**Cilium/Calico phase ordering:** `Main.ps1` detects `CNIPlugin -in @('cilium', 'calico')` and runs Phase 8 (`Apply-CNI.ps1`) *before* Phase 7 (`Join-Nodes.ps1`) so that nodes have a CNI when they join.

---

## Output Files

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
