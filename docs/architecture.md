# Architecture — Hyper-V k3s Cluster

Two-node Kubernetes cluster running entirely on a single Windows 11 host via Hyper-V. The control plane runs on Linux; Windows Server acts as a worker node.

## Physical Layout

```
┌─────────────────────────────────────────────────────────────────┐
│  Windows 11 Host                                                │
│                                                                 │
│  ┌───────────────────────────┐  ┌────────────────────────────┐  │
│  │  k8s-linux-master         │  │  k8s-windows-worker        │  │
│  │  Ubuntu 24.04 LTS         │  │  Windows Server 2022 Eval  │  │
│  │  2 vCPU / 4 GB RAM        │  │  4 vCPU / 7 GB RAM         │  │
│  │  60 GB VHDX               │  │  60 GB VHDX                │  │
│  └─────────────┬─────────────┘  └──────────────┬─────────────┘  │
│                │                               │                │
│                └───────────┬───────────────────┘                │
│                      k8s-external                               │
│                  (Hyper-V External vSwitch)                     │
│                            │                                    │
└────────────────────────────┼────────────────────────────────────┘
                             │
                    Home/Office Router
                    (DHCP, same L2 subnet)
```

Both VMs receive DHCP addresses from the router. The external vSwitch bridges them onto the host's physical NIC — all three (host, Linux VM, Windows VM) are on the same L2 segment.

## Kubernetes Components

### Linux VM — k3s Server (control plane + Linux worker)

| Component | Version | Installed by | Notes |
|-----------|---------|--------------|-------|
| k3s | v1.32.5+k3s1 | `02-k3s-server.sh` | Bundles API server, scheduler, controller-manager, etcd, kubelet, containerd, flannel |
| containerd | 2.0.5-k3s1.32 | bundled with k3s | Linux pods only |
| Flannel | embedded | k3s | host-gw backend; manages Linux routing table |
| CoreDNS | embedded | k3s | ClusterIP `10.43.0.10` |
| local-path-provisioner | embedded | k3s | default StorageClass |

k3s is installed via the official install script with:
```
--disable traefik
--flannel-backend=host-gw
--node-label kubernetes.io/os=linux
--write-kubeconfig-mode 0644
```

`host-gw` is required because Windows flannel cannot use VXLAN tunnelling — pods communicate via direct L2 routing entries programmed in the host OS routing table.

k3s also pre-creates Kubernetes resources needed by the Windows worker:
- `kube-flannel` namespace
- `flannel` ServiceAccount + ClusterRole/Binding (node read/patch)
- `kube-flannel-cfg` ConfigMap with `net-conf.json` matching the cluster CIDR
- A long-lived ServiceAccount token for flanneld authentication

### Windows VM — upstream Kubernetes worker

The Windows node does **not** run k3s. It uses upstream Kubernetes binaries that speak the standard Kubernetes API — they work unchanged against the k3s control plane.

#### Installed binaries (`C:\k\`)

| Binary | Version | Source | Role |
|--------|---------|--------|------|
| `kubelet.exe` | v1.32.5 | dl.k8s.io | Node agent; registers with k3s API server |
| `kube-proxy.exe` | v1.32.5 | dl.k8s.io | kernelspace mode; programs HNS load-balancing rules |
| `kubectl.exe` | v1.32.5 | dl.k8s.io | Used by `start-network.ps1` to query pod CIDR |
| `containerd.exe` | v1.7.32 | GitHub releases | Container runtime (pinned — see below) |
| `flanneld.exe` | — | not installed | **Not used**; replaced by `start-network.ps1` |

#### CNI plugins (`C:\k\cni\`)

| Plugin | Source | Role |
|--------|--------|------|
| `flannel.exe` | flannel v0.25.7 release | CNI wrapper; delegates to win-bridge |
| `win-bridge.exe` | microsoft/windows-container-networking v0.3.0 | Creates HNS endpoints for pods |
| `win-overlay.exe` | microsoft/windows-container-networking v0.3.0 | Bundled; unused (host-gw mode) |
| `host-local.exe` | containernetworking/plugins v1.5.1 | IPAM (assigns pod IPs from node CIDR) |
| `hns.psm1` | microsoft/SDN | PowerShell HNS helpers |

#### Windows features

| Feature | Installed by |
|---------|--------------|
| Containers | `02-containers.ps1` (triggers reboot) |
| Hyper-V | `02-containers.ps1` (for Hyper-V isolation; enables nested virt) |

#### Services and scheduled tasks

| Name | Type | Startup | Role |
|------|------|---------|------|
| `containerd` | Windows Service | Automatic | Container runtime |
| `kubelet` | Windows Service | Automatic | Registers node, manages pod lifecycle |
| `StartNetwork` | Scheduled Task (SYSTEM, AtStartup) | — | Creates cbr0 HNS L2Bridge; waits up to 600 s for pod CIDR |
| `StartKubeProxy` | Scheduled Task (SYSTEM, AtStartup) | — | Waits up to 300 s for cbr0, then starts kube-proxy |

#### Key files

| Path | Contents |
|------|----------|
| `C:\k\kubeconfig.yaml` | Admin kubeconfig (server IP patched at Packer build time) |
| `C:\k\flannel-kubeconfig.yaml` | Flannel ServiceAccount kubeconfig (read-only node perms) |
| `C:\k\kubelet-config.yaml` | KubeletConfiguration (DNS, container runtime endpoint) |
| `C:\k\cni\config\10-flannel.conflist` | CNI chain: flannel → win-bridge with OutboundNAT + ROUTE policies |
| `C:\containerd\config\config.toml` | containerd config; runtime: `runhcs-wcow-process` |
| `C:\k\start-network.ps1` | Pod network bootstrap (generated at build time) |
| `C:\k\start-kube-proxy.ps1` | kube-proxy bootstrap (generated at build time) |
| `C:\k\network.log` | Runtime log for start-network.ps1 |
| `C:\k\kube-proxy.log` | Runtime log for start-kube-proxy.ps1 |

## Network Architecture

```
Pod CIDR     : 10.42.0.0/16  (k3s default)
Service CIDR : 10.43.0.0/16  (k3s default)
CoreDNS      : 10.43.0.10

Node pod allocations (assigned by k3s):
  k8s-linux-master  → 10.42.0.0/24
  k8s-win-worker    → 10.42.1.0/24  (example)
```

### Flannel host-gw mode

Each node's pod CIDR is routed via direct OS routing table entries. No tunnelling, no encapsulation — pods on different nodes communicate via the L2-reachable node IPs (both VMs are on the same physical subnet).

```
Linux node routing table (managed by embedded flannel):
  10.42.1.0/24  via <Windows VM IP>   (Windows node pod CIDR)

Windows node routing table (written by start-network.ps1):
  10.42.0.0/24  via <Linux VM IP>     (Linux node pod CIDR)
```

### Windows networking internals

```
kubelet registers node
      │
      ▼
k3s assigns pod CIDR to node
      │
      ▼ (start-network.ps1, up to 600 s)
Creates cbr0 HNS L2Bridge network
Writes 10-flannel.conflist with actual CIDR
Adds Linux node route to Windows routing table
      │
      ▼ (start-kube-proxy.ps1, up to 300 s after cbr0 appears)
Starts kube-proxy.exe (kernelspace, source-vip = cbr0 gateway IP)
```

HNS (Host Networking Service) provides Windows equivalents of Linux network namespaces and veth pairs. The `cbr0` L2Bridge HNS network is the Windows equivalent of a Linux bridge — containerd attaches each pod sandbox to it via `win-bridge`.

### containerd on Windows — version pin

containerd is pinned to **v1.7.x** (`1.7.32`). containerd v2.x removed the CRI v1 gRPC API (`runtime.v1.RuntimeService`). kubelet v1.32 uses CRI v1 and cannot connect to a v2.x containerd. The pin is enforced in `config/variables.ps1`:
```powershell
$script:ContainerdVersion = '1.7.32'
```

## Build Process

Both VMs are built from scratch using [Packer](https://www.packer.io/) with the `hyperv-iso` builder.

### Linux VM build sequence

| Step | Script | What it does |
|------|--------|--------------|
| cloud-init | `packer/linux/http/user-data` | Autoinstall Ubuntu; injects SSH key for Packer |
| 1 | `01-base.sh` | apt packages, kernel modules, sysctl, disable swap |
| 2 | `02-k3s-server.sh` | Install k3s; create flannel RBAC + token for Windows workers |
| 3 | `03-export-kubeconfig.sh` | Export kubeconfig + flannel kubeconfig to `/tmp/` for Packer to retrieve |

### Windows VM build sequence

| Step | Script | What it does |
|------|--------|--------------|
| autounattend | `packer/windows/autounattend/autounattend.xml` | Unattended install; WinRM; hostname `k8s-win-worker` |
| 1 | `01-base.ps1` | ExecutionPolicy, firewall, WinRM hardening, disable IPv6 Teredo |
| 2 | `02-containers.ps1` | Enable Containers + Hyper-V features (triggers reboot) |
| 3 | `03-containerd.ps1` | Install containerd v1.7.32; generate `config.toml` |
| 4 | `04-k3s-agent.ps1` | Install kubelet/kube-proxy/kubectl; CNI plugins; write startup scripts; register services + scheduled tasks |

The Windows VM build receives the Linux VM's IP, admin kubeconfig, and flannel kubeconfig as Packer variables (base64-encoded). These are baked into the VHDX at build time.

## Name Split

The Hyper-V VM name and the Kubernetes node name are different:

| Identifier | Value | Used in |
|------------|-------|---------|
| `$script:WindowsVMName` | `k8s-windows-worker` | Hyper-V cmdlets (`Get-VM`, `Start-VM`) |
| `$script:WindowsNodeName` | `k8s-win-worker` | `kubectl get node`, node labels |
| `$script:LinuxVMName` | `k8s-linux-master` | Both — the VM name and the k8s node name match |

Windows hostnames are limited to 15 characters; `k8s-windows-worker` (18 chars) cannot be the hostname.

## Output Files

After a successful build, `output/` contains:

| File | Contents |
|------|----------|
| `kubeconfig.yaml` | Admin kubeconfig with Linux VM's current IP patched in |
| `cluster-info.txt` | Node IPs and cluster CIDR summary |
| `linux-build-key` | Ed25519 private key (SSH into Linux VM) |
| `linux-build-key.pub` | Corresponding public key (embedded in cloud-init user-data) |
| `linux-vm-ip.txt` | Last known Linux VM IP |
| `windows-vm-ip.txt` | Last known Windows VM IP |
| `sentinels/phase-phaseN.done` | Idempotency markers for each phase |
