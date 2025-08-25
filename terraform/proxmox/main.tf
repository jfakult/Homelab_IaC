terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.82.1"
    }
  }
  required_version = ">= 1.3.0"
}

provider "proxmox" {
  endpoint = "https://192.168.1.200:8006/api2/json"
  api_token = var.proxmox_token
  insecure = true # if self-signed certs
}

locals {
  node_name    = "butlah"                             # Your Proxmox node name
  storage_pool = "local-lvm"                          # Or "local-zfs", adjust to match your Proxmox setup
  template     = "9000"                               # The base cloud-init VM/template name
}

# Foreach clones from template and terraform.tfvars
resource "proxmox_virtual_environment_vm" "vm" {
  for_each    = var.vms
  vm_id       = each.value.id
  node_name   = local.node_name
  name        = each.key
  description = each.value.purpose

  initialization {
    user_data_file_id = "local:snippets/cloud-init.yaml" # /var/lib/vz/snippets

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = "192.168.1.1"
      }
    }
  }

  clone {
    vm_id = local.template
  }

  agent { enabled = true }

  # Only override sizes if needed
  cpu {
    cores   = each.value.cores
    sockets = 1
  }

  memory {
    dedicated = each.value.memory
    floating  = each.value.balloon
  }

  disk {
    datastore_id = local.storage_pool
    interface    = "scsi0"
    size         = each.value.disk   # MB
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }
}