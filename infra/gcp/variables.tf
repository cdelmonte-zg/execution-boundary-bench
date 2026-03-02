variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "europe-west1-b"
}

variable "machine_type" {
  description = "GCE machine type — must support nested virtualization"
  type        = string
  default     = "n2-standard-4"
}

variable "node_count" {
  description = "Number of worker nodes (control plane is always 1)"
  type        = number
  default     = 2
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for node access"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_user" {
  description = "SSH username"
  type        = string
  default     = "bench"
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
