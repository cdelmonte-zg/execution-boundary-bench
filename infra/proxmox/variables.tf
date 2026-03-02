variable "proxmox_endpoint" {
  description = "Proxmox API URL (e.g. https://192.168.1.100:8006)"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token (format: user@realm!tokenid=secret)"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name to deploy VMs on"
  type        = string
}

variable "proxmox_datastore" {
  description = "Storage pool for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "proxmox_iso_datastore" {
  description = "Storage pool for ISO/cloud images (must support 'iso' content type)"
  type        = string
  default     = "local"
}

variable "cloud_image_url" {
  description = "URL of the Ubuntu 22.04 cloud image (qcow2)"
  type        = string
  default     = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
}

variable "vm_cores" {
  description = "vCPU cores per VM"
  type        = number
  default     = 4
}

variable "vm_memory_mb" {
  description = "Memory per VM in MB"
  type        = number
  default     = 16384
}

variable "vm_disk_gb" {
  description = "Disk size per VM in GB"
  type        = number
  default     = 40
}

variable "node_count" {
  description = "Number of worker nodes (control plane is always 1)"
  type        = number
  default     = 2
}

variable "network_bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "ip_base" {
  description = "Base IP for VMs (e.g. 192.168.1.200) — control plane gets this, workers get +1, +2..."
  type        = string
  default     = "192.168.1.200"
}

variable "gateway" {
  description = "Network gateway"
  type        = string
  default     = "192.168.1.1"
}

variable "nameserver" {
  description = "DNS nameserver"
  type        = string
  default     = "1.1.1.1"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for VM access"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "k8s_version" {
  description = "Kubernetes minor version"
  type        = string
  default     = "1.29"
}

variable "pod_cidr" {
  description = "Pod network CIDR for kubeadm"
  type        = string
  default     = "10.244.0.0/16"
}

variable "vm_id_base" {
  description = "Starting VM ID in Proxmox"
  type        = number
  default     = 9000
}
