terraform {
  required_version = ">= 1.13.1, < 2.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.115.0"
    }
  }
}

provider "proxmox" {}

variable "vms" {
  description = "VM hardware to manage. Keep empty until the intended Proxmox IDs and storage are confirmed."
  type = map(object({
    vm_id        = number
    node_name    = string
    ssd_storage  = string
    hdd_storage  = string
    iso_file_id  = optional(string, "none")
    bridge       = optional(string, "vmbr0")
    mac_address  = string
    cores        = optional(number, 4)
    memory_mb    = optional(number, 8192)
    boot_disk_gb = optional(number, 64)
    data_disk_gb = optional(number, 128)
    started      = optional(bool, false)
  }))
  default = {}

  validation {
    condition     = length(distinct([for vm in values(var.vms) : vm.vm_id])) == length(var.vms)
    error_message = "VM IDs must be unique."
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = var.vms

  name          = each.key
  node_name     = each.value.node_name
  vm_id         = each.value.vm_id
  bios          = "ovmf"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0", "ide2"]
  started       = each.value.started

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  efi_disk {
    datastore_id = each.value.ssd_storage
    type         = "4m"
  }

  disk {
    datastore_id = each.value.ssd_storage
    interface    = "scsi0"
    size         = each.value.boot_disk_gb
    ssd          = true
    discard      = "on"
    iothread     = true
  }

  disk {
    datastore_id = each.value.hdd_storage
    interface    = "scsi1"
    size         = each.value.data_disk_gb
    iothread     = true
  }

  cdrom {
    file_id   = each.value.iso_file_id
    interface = "ide2"
  }

  network_device {
    bridge      = each.value.bridge
    model       = "virtio"
    mac_address = each.value.mac_address
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    prevent_destroy = true
  }
}
