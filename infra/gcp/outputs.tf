output "control_plane_external_ip" {
  description = "Public IP of the control plane node"
  value       = google_compute_instance.control_plane.network_interface[0].access_config[0].nat_ip
}

output "control_plane_internal_ip" {
  description = "Internal IP of the control plane node"
  value       = google_compute_instance.control_plane.network_interface[0].network_ip
}

output "worker_external_ips" {
  description = "Public IPs of worker nodes"
  value       = [for w in google_compute_instance.worker : w.network_interface[0].access_config[0].nat_ip]
}

output "worker_internal_ips" {
  description = "Internal IPs of worker nodes"
  value       = [for w in google_compute_instance.worker : w.network_interface[0].network_ip]
}

output "ssh_command" {
  description = "SSH into control plane"
  value       = "ssh ${var.ssh_user}@${google_compute_instance.control_plane.network_interface[0].access_config[0].nat_ip}"
}

output "environment" {
  value = "gcp"
}
