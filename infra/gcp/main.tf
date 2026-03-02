terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# -------------------------------------------------------------------
# Network
# -------------------------------------------------------------------

resource "google_compute_network" "bench" {
  name                    = "bench-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "bench" {
  name          = "bench-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.bench.id
}

resource "google_compute_firewall" "internal" {
  name    = "bench-allow-internal"
  network = google_compute_network.bench.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/24"]
}

resource "google_compute_firewall" "ssh" {
  name    = "bench-allow-ssh"
  network = google_compute_network.bench.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

# -------------------------------------------------------------------
# Custom image with nested virtualization license
# -------------------------------------------------------------------

resource "google_compute_image" "ubuntu_nested_virt" {
  name             = "bench-ubuntu-2204-nested-virt"
  source_image     = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
  storage_locations = [var.region]

  licenses = [
    "https://www.googleapis.com/compute/v1/projects/vm-options/global/licenses/enable-vmx"
  ]
}

# -------------------------------------------------------------------
# Control plane
# -------------------------------------------------------------------

resource "google_compute_instance" "control_plane" {
  name         = "bench-cp"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = google_compute_image.ubuntu_nested_virt.self_link
      size  = 40
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.bench.id
    access_config {} # ephemeral public IP
  }

  metadata = {
    ssh-keys  = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
    user-data = templatefile("${path.module}/../shared/cloud-init.yaml.tpl", {
      node_role        = "control-plane"
      control_plane_ip = ""
      join_token       = ""
      cert_hash        = ""
      k8s_version      = var.k8s_version
      pod_cidr         = var.pod_cidr
      ssh_public_key   = trimspace(file(var.ssh_public_key_path))
      hostname         = "bench-cp"
    })
  }

  min_cpu_platform = "Intel Cascade Lake" # ensures VMX support

  scheduling {
    preemptible       = false
    automatic_restart = true
  }

  tags = ["bench-cluster"]

  service_account {
    scopes = ["compute-ro", "storage-ro"]
  }
}

# -------------------------------------------------------------------
# Workers
# -------------------------------------------------------------------

resource "google_compute_instance" "worker" {
  count        = var.node_count
  name         = "bench-worker-${count.index + 1}"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = google_compute_image.ubuntu_nested_virt.self_link
      size  = 40
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.bench.id
    access_config {}
  }

  metadata = {
    ssh-keys  = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
    user-data = templatefile("${path.module}/../shared/cloud-init.yaml.tpl", {
      node_role        = "worker"
      control_plane_ip = google_compute_instance.control_plane.network_interface[0].network_ip
      join_token       = "PLACEHOLDER"
      cert_hash        = "PLACEHOLDER"
      k8s_version      = var.k8s_version
      pod_cidr         = var.pod_cidr
      ssh_public_key   = trimspace(file(var.ssh_public_key_path))
      hostname         = "bench-worker-${count.index + 1}"
    })
  }

  min_cpu_platform = "Intel Cascade Lake"

  scheduling {
    preemptible       = false
    automatic_restart = true
  }

  tags = ["bench-cluster"]

  service_account {
    scopes = ["compute-ro", "storage-ro"]
  }

  depends_on = [google_compute_instance.control_plane]
}
