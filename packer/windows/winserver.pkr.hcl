# =============================================================================
# packer/windows/winserver.pkr.hcl
# Builds the Windows Server 2025 Core k3s agent (Windows worker node) VM.
# Uses the Hyper-V ISO builder with WinRM communicator.
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
# Variables (injected by Build-WindowsVM.ps1 via -var flags)
# ---------------------------------------------------------------------------
variable "vm_name" {
  type    = string
  default = "k8s-windows-worker"
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
  default = "../../vhdx/windows"
}
# Kubernetes version string (no +k3sN suffix), e.g. v1.32.5
# Used to download upstream kubelet.exe and kube-proxy.exe from dl.k8s.io
variable "k8s_version" {
  type    = string
  default = "v1.32.5"
}
variable "k3s_server_ip" {
  type = string
}
# base64-encoded k3s admin kubeconfig (server IP already patched to k3s_server_ip)
variable "kubeconfig_b64" {
  type      = string
  sensitive = true
}
# base64-encoded flannel ServiceAccount kubeconfig (limited node-read permissions)
variable "flannel_kubeconfig_b64" {
  type      = string
  sensitive = true
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
  default = "2.3.1"
}

# ---------------------------------------------------------------------------
source "hyperv-iso" "winserver" {
  vm_name          = var.vm_name
  cpus             = var.cpu_count
  memory           = var.memory_mb
  disk_size        = var.disk_size_mb
  switch_name      = var.switch_name
  generation       = 1          # Gen 1 for broadest driver compatibility with WS Core
  enable_dynamic_memory = false
  guest_additions_mode = "disable"

  iso_url          = var.iso_path
  iso_checksum     = "none"     # local eval ISO; checksum verified by download script

  # Mount autounattend as a secondary floppy image
  floppy_files     = ["autounattend/autounattend.xml"]

  # WinRM communicator
  communicator     = "winrm"
  winrm_username   = "Administrator"
  winrm_password   = var.admin_pass
  winrm_timeout    = "90m"
  winrm_use_ssl    = false
  winrm_insecure   = true
  winrm_port       = 5985

  boot_wait        = "3s"
  # No boot_command needed — autounattend.xml drives the install fully

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout = "15m"

  output_directory = var.output_dir
  headless         = true
}

# ---------------------------------------------------------------------------
build {
  name    = "winserver-k3s-agent"
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
    restart_timeout      = "15m"
    restart_check_command = "powershell -command \"Get-WindowsFeature Containers | Where-Object {$_.InstallState -eq 'Installed'}\""
  }

  # --- 3: Install containerd ---
  provisioner "powershell" {
    script = "scripts/03-containerd.ps1"
    environment_vars = [
      "CONTAINERD_VERSION=${var.containerd_version}"
    ]
  }

  # --- 4: Install upstream kubelet + flanneld + kube-proxy ---
  provisioner "powershell" {
    script = "scripts/04-k3s-agent.ps1"
    environment_vars = [
      "K8S_VERSION=${var.k8s_version}",
      "K3S_SERVER_IP=${var.k3s_server_ip}",
      "KUBECONFIG_B64=${var.kubeconfig_b64}",
      "FLANNEL_KUBECONFIG_B64=${var.flannel_kubeconfig_b64}",
      "CLUSTER_DNS_IP=${var.cluster_dns_ip}",
      "CLUSTER_CIDR=${var.cluster_cidr}",
      "SERVICE_CIDR=${var.service_cidr}",
      "FLANNEL_VERSION=${var.flannel_version}",
      "WINS_CNI_VERSION=${var.wins_cni_version}"
    ]
  }
}
