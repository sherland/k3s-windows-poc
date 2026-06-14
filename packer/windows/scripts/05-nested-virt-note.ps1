# =============================================================================
# packer/windows/scripts/05-nested-virt-note.ps1
# This script intentionally does nothing inside the VM.
# Nested virtualisation (required for Hyper-V container isolation) must be
# enabled on the Hyper-V HOST using Set-VMProcessor BEFORE the VM is started
# for the Containers + Hyper-V feature provisioning pass.
#
# Build-WindowsVM.ps1 handles this automatically.
# This file exists as documentation / placeholder.
# =============================================================================

Write-Host '[05-nested-virt-note] Nested virtualisation is configured on the host ' +
           'by Build-WindowsVM.ps1 before this VM boots. No in-VM action needed.'
