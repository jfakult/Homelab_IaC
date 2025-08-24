# SSH public key (inline example, but best to read from file)
ssh_public_key = <<EOT
ssh-ed25519 xxx
EOT

# SSH user (default is ubuntu, override if needed)
ssh_user = "ubuntu"
proxmox_token = "terraform@pam!terraform_token_id=xxx"

# VM definitions
vms = {
  bastion = {
    id      = 01
    ip      = "10.0.0.1"
    purpose = "Ingress proxy + Fail2ban"
    memory  = 2048
  }

  dns = {
    id      = 02
    ip      = "10.0.0.2"
    purpose = "Pi-hole DNS"
    memory  = 1024
  }

  db = {
    id      = 03
    ip      = "10.0.0.3"
    purpose = "Postgres"
    cores   = 4
    memory  = 8192
    disk    = 32      # Most will probably be on the NAS but who knows. Can expand later
  }

  sso = {
    id      = 04
    ip      = "10.0.0.4"
    purpose = "Authelia + auth gateway"
  }

  webapps = {
    id      = 05
    ip      = "10.0.0.5"
    purpose = "Webapps dashboard"
    cores   = 8
    memory  = 16384               # To allow for "heavy" services like gitlab. Might move it later
    balloon = 4096
    disk    = 16
  }

  media = {
    id      = 06
    ip      = "10.0.0.6"
    purpose = "Jellyfin"
    cores   = 8                   # 4 might be fine. Needs testing
    memory  = 8192
    disk    = 16                  # Most will be stored on NAS. Cache / Metadata will be local
  }

  storage = {
    id      = 07
    ip      = "10.0.0.7"
    purpose = "Immich, Paperless, Nextcloud"
    memory  = 8192
    disk    = 32                  # Most will be stored on NAS. Might selectively move some to SSD
  }

  compute = {
    id      = 08
    ip      = "10.0.0.8"
    purpose = "AI workloads"
    cores   = 16
    memory  = 32768
    disk    = 128                 # Enough to keep a few relevant models on SSD. Others can be on NAS
    balloon = 16384
  }

  containerlab = {
    id      = 09
    ip      = "10.0.0.9"
    purpose = "Network labs"
    memory  = 16384
    balloon = 8192
    disk    = 30
  }

  misc = {
    id      = 10
    ip      = "10.0.0.10"
    purpose = "Scratchpad, experiments, ad-hoc games"
    memory  = 8192
    cores   = 4
    balloon = 2048
  }
}