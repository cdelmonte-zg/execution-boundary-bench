terraform {
  required_version = ">= 1.5"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # self-signed certs typical in homelab

  ssh {
    agent    = true
    username = "root"
  }
}

# -------------------------------------------------------------------
# Cloud image template
# -------------------------------------------------------------------

resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  content_type = "iso"
  datastore_id = var.proxmox_iso_datastore
  node_name    = var.proxmox_node
  url          = var.cloud_image_url
  file_name    = "jammy-server-cloudimg-amd64.img"
}

# -------------------------------------------------------------------
# Helper: compute IP for node index
# -------------------------------------------------------------------

locals {
  ip_parts = split(".", var.ip_base)
  ip_prefix = join(".", slice(local.ip_parts, 0, 3))
  ip_last   = tonumber(local.ip_parts[3])

  cp_ip     = var.ip_base
  worker_ips = [
    for i in range(var.node_count) :
    "${local.ip_prefix}.${local.ip_last + i + 1}"
  ]
}

# -------------------------------------------------------------------
# Cloud-init snippets
# -------------------------------------------------------------------

resource "proxmox_virtual_environment_file" "cloud_init_cp" {
  content_type = "snippets"
  datastore_id = var.proxmox_iso_datastore
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/../shared/cloud-init.yaml.tpl", {
      node_role        = "control-plane"
      control_plane_ip = ""
      join_token       = ""
      cert_hash        = ""
      k8s_version      = var.k8s_version
      pod_cidr         = var.pod_cidr
      ssh_public_key   = trimspace(file(var.ssh_public_key_path))
      hostname         = "bench-cp"
    })
    file_name = "bench-cp-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_file" "cloud_init_worker" {
  count        = var.node_count
  content_type = "snippets"
  datastore_id = var.proxmox_iso_datastore
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/../shared/cloud-init.yaml.tpl", {
      node_role        = "worker"
      control_plane_ip = local.cp_ip
      join_token       = "PLACEHOLDER"
      cert_hash        = "PLACEHOLDER"
      k8s_version      = var.k8s_version
      pod_cidr         = var.pod_cidr
      ssh_public_key   = trimspace(file(var.ssh_public_key_path))
      hostname         = "bench-worker-${count.index + 1}"
    })
    file_name = "bench-worker-${count.index + 1}-cloud-init.yaml"
  }
}

# -------------------------------------------------------------------
# Control plane VM
# -------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "control_plane" {
  name      = "bench-cp"
  node_name = var.proxmox_node
  vm_id     = var.vm_id_base

  cpu {
    cores = var.vm_cores
    type  = "host" # passthrough — required for nested KVM
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  agent {
    enabled = true
  }

  disk {
    datastore_id = var.proxmox_datastore
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "scsi0"
    size         = var.vm_disk_gb
    iothread     = true
    discard      = "on"
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.cp_ip}/24"
        gateway = var.gateway
      }
    }
    dns {
      servers = [var.nameserver]
    }
    user_account {
      keys     = [trimspace(file(var.ssh_public_key_path))]
      username = "bench"
    }
    user_data_file_id = proxmox_virtual_environment_file.cloud_init_cp.id
  }

  operating_system {
    type = "l26"
  }

  on_boot = true

  lifecycle {
    ignore_changes = [disk[0].file_id]
  }
}

# -------------------------------------------------------------------
# Worker VMs
# -------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "worker" {
  count     = var.node_count
  name      = "bench-worker-${count.index + 1}"
  node_name = var.proxmox_node
  vm_id     = var.vm_id_base + count.index + 1

  cpu {
    cores = var.vm_cores
    type  = "host" # passthrough — KVM inside VM for Kata/KubeVirt
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  agent {
    enabled = true
  }

  disk {
    datastore_id = var.proxmox_datastore
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    interface    = "scsi0"
    size         = var.vm_disk_gb
    iothread     = true
    discard      = "on"
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.worker_ips[count.index]}/24"
        gateway = var.gateway
      }
    }
    dns {
      servers = [var.nameserver]
    }
    user_account {
      keys     = [trimspace(file(var.ssh_public_key_path))]
      username = "bench"
    }
    user_data_file_id = proxmox_virtual_environment_file.cloud_init_worker[count.index].id
  }

  operating_system {
    type = "l26"
  }

  on_boot = true

  depends_on = [proxmox_virtual_environment_vm.control_plane]

  lifecycle {
    ignore_changes = [disk[0].file_id]
  }
}
