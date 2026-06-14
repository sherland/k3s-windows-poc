# =============================================================================
# packer/windows/winserver.pkr.hcl
# Builds a Windows Server golden base VHDX for k3s worker nodes.
# Supports WS2022 and WS2025 via the os_version variable.
# The resulting VHDX is the read-only parent for per-node differencing disks.
# =============================================================================

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    hyperv = {
      version = ">= 1.1.3"
      source  = "github.com/hashicorp/hyperv"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables (injected by Build-WindowsBase.ps1 via -var flags)
# ---------------------------------------------------------------------------
variable "os_version" {
  type    = string
  default = "2025"
  # Valid: "2022" | "2025"
}
variable "vm_name" {
  type    = string
  default = "k8s-windows-base"
}
variable "cpu_count" {
  type    = number
  default = 4
}
variable "memory_mb" {
  type    = number
  default = 7168
}
variable "disk_size_mb" {
  type    = number
  default = 61440
}
variable "switch_name" {
  type    = string
  default = "k8s-external"
}
variable "admin_pass" {
  type      = string
  default   = "ChangeMe123!"
  sensitive = true
}
variable "iso_path" {
  type = string
}
variable "output_dir" {
  type    = string
  default = "../../vhdx/windows-base"
}
# Kubernetes version string (no +k3sN suffix), e.g. v1.32.5
# Used to download upstream kubelet.exe and kube-proxy.exe from dl.k8s.io
variable "k8s_version" {
  type    = string
  default = "v1.32.5"
}
variable "cluster_dns_ip" {
  type    = string
  default = "10.43.0.10"
}
variable "cluster_cidr" {
  type    = string
  default = "10.42.0.0/16"
}
variable "service_cidr" {
  type    = string
  default = "10.43.0.0/16"
}
variable "flannel_version" {
  type    = string
  default = "v0.25.7"
}
variable "wins_cni_version" {
  type    = string
  default = "v0.3.0"
}
variable "containerd_version" {
  type    = string
  default = "1.7.32"
}

# ---------------------------------------------------------------------------
source "hyperv-iso" "winserver" {
  vm_name               = var.vm_name
  cpus                  = var.cpu_count
  memory                = var.memory_mb
  disk_size             = var.disk_size_mb
  switch_name           = var.switch_name
  generation            = 1          # Gen 1 for broadest driver compatibility
  enable_dynamic_memory = false
  guest_additions_mode  = "disable"

  iso_url      = var.iso_path
  iso_checksum = "none"     # local eval ISO; checksum verified by download script

  # floppy_files places each listed file at the ROOT of the floppy (A:\).
  # Windows Setup only looks for autounattend.xml at the floppy root — floppy_dirs
  # would copy the directory itself (A:\2022\autounattend.xml) which Setup ignores.
  floppy_files = [
    "autounattend/${var.os_version}/autounattend.xml",
    "autounattend/${var.os_version}/winrm-setup.ps1",
  ]

  # WinRM communicator
  communicator  = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_pass
  winrm_timeout  = "90m"
  winrm_use_ssl  = false
  winrm_insecure = true
  winrm_port     = 5985

  boot_wait = "30s"   # Windows Setup reads autounattend immediately; 30s is enough for Hyper-V to initialise

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout = "15m"

  output_directory = var.output_dir
  headless         = false   # show VM console so we can observe Windows setup progress
}

# ---------------------------------------------------------------------------
build {
  name    = "winserver-k3s-base"
  sources = ["source.hyperv-iso.winserver"]

  # --- 1: Base hardening & WinRM tuning ---
  provisioner "powershell" {
    script = "scripts/01-base.ps1"
  }

  # --- 2: Install Containers + Hyper-V features ---
  provisioner "powershell" {
    script = "scripts/02-containers.ps1"
  }

  # Packer waits for WinRM to come back after the feature-install reboot
  provisioner "windows-restart" {
    restart_timeout       = "15m"
    restart_check_command = "powershell -command \"Get-WindowsFeature Containers | Where-Object {$_.InstallState -eq 'Installed'}\""
  }

  # --- 3: Install containerd (pinned to v1.x for CRI v1 gRPC API compatibility) ---
  provisioner "powershell" {
    script = "scripts/03-containerd.ps1"
    environment_vars = [
      "CONTAINERD_VERSION=${var.containerd_version}"
    ]
  }

  # --- 4: Install Kubernetes binaries (kubelet, kube-proxy, kubectl, flanneld, CNI plugins) ---
  #         Also writes static config files and registers StartNetwork/StartKubeProxy tasks.
  #         Does NOT write per-node kubeconfigs — those are injected offline by Join-Nodes.ps1.
  provisioner "powershell" {
    script = "scripts/04-install-k8s-binaries.ps1"
    environment_vars = [
      "K8S_VERSION=${var.k8s_version}",
      "CLUSTER_DNS_IP=${var.cluster_dns_ip}",
      "CLUSTER_CIDR=${var.cluster_cidr}",
      "SERVICE_CIDR=${var.service_cidr}",
      "FLANNEL_VERSION=${var.flannel_version}",
      "WINS_CNI_VERSION=${var.wins_cni_version}"
    ]
  }

  # --- 5: Create C:\k8s-firstboot.ps1 template + scheduled task ---
  #         First-boot script reads C:\k8s-node-config.json (injected per-node by Join-Nodes.ps1)
  #         and registers kubelet service, writes kubeconfigs, renames computer, reboots.
  provisioner "powershell" {
    script = "scripts/05-firstboot-setup.ps1"
  }
}

