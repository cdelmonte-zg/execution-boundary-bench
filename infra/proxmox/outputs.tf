output "control_plane_ip" {
  description = "IP of the control plane node"
  value       = local.cp_ip
}

output "worker_ips" {
  description = "IPs of worker nodes"
  value       = local.worker_ips
}

output "ssh_command" {
  description = "SSH into control plane"
  value       = "ssh bench@${local.cp_ip}"
}

output "vm_ids" {
  description = "Proxmox VM IDs"
  value = {
    control_plane = proxmox_virtual_environment_vm.control_plane.vm_id
    workers       = [for w in proxmox_virtual_environment_vm.worker : w.vm_id]
  }
}

output "environment" {
  value = "proxmox"
}
