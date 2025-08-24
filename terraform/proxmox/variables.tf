# defined in terraform.tfvars
variable "proxmox_token" {
  type        = string
  description = "Proxmox API token in format: user@pam!tokenid=secret"
}
variable "ssh_public_key" {
  type        = string
  description = "SSH public key for cloud-init"
}
variable "ssh_user" {
  description = "Default SSH user created by cloud-init"
  type        = string
  default     = "ubuntu"
}

# Used to define virtual machines. See terraform.tfvars
variable "vms" {
  description = "VM definitions"
  type = map(object({
    id      = number
    ip      = string
    purpose = string
    cores   = optional(number, 2)     # template default = 2
    memory  = optional(number, 4096)  # template default = 4 GB
    balloon = optional(number, 2048)  # template default = 2 GB
    disk    = optional(number, 10)    # template default = 10 GB
  }))
}