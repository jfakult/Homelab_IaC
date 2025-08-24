🗺️ **Infrastructure Blueprint**
--------------------------------

### 🔹 Network

*   **Subnet**: `x.x.x.0/24`
    
*   **Router**: already configured, allows ingress only on ports `80, 443, 2222`
    
*   **Proxmox host**: `ID = 00`
    
*   **VM addressing**: static, via Terraform/Proxmox cloud-init
    

* * *

### 🔹 VM Inventory

| VM | IP | Purpose | Notes |
| --- | --- | --- | --- |
| Bastion / Jump (Reverse Proxy) | ID = 01 | Ingress only (80,443,2222), Nginx reverse proxy, Fail2ban | External facing |
| DNS | ID = 02 | Internal only | Pi-hole |
| DB | ID = 03 | Data on NAS | Postgres |
| SSO | ID = 04 | Authelia + dependencies | For auth gateway |
| Webapps | ID = 05 | Node, FastAPI, static apps | Needs app-dashboard (SUI/Heimdall/Homepage) |
| Media | ID = 06 | Jellyfin | Metadata local SSD, media on NAS |
| Storage | ID = 07 | Immich, Paperless, Nextcloud | Heavy NAS usage |
| Compute | ID = 08 | AI GPU workloads | LLM, coding assistant, image gen |
| Containerlab | ID = 09 | FRR/EVPN/MPLS labs | For network engineering experiments |
| Misc | ID = 10 | Scratchpad, experiments | Catch-all |

* * *

⚙️ **Terraform Layer (Proxmox VM Creation)**
--------------------------------------------

*   Each VM defined as `proxmox_vm_qemu` resource with:
    
    *   Base cloud-init template (ubuntu-24.04-server-cloudimg-amd64.img)

    *   Then converted via goldenize.sh to ubuntu-24.04-server-cloudimg-amd64-golden.img

    *   Static IP via cloud-init
        
    *   SSH keys injected, password required for root elevation (via cloud-init)
        
    *   Base CPU/RAM/disk (customizable from `terraform/proxmox/terraform.tfvars`)
        
*   Define all in one Terraform file, e.g. `terraform/proxmox/main.tf`
    
*   Run `terraform plan` / `apply` → all VMs boot with correct networking & keys.
    

* * *

⚙️ **Ansible Layer (Configuration & Services)**
-----------------------------------------------

Organize into **roles**, then combine in `site.yml`.

*   **Base role (all hosts)**: updates, security hardening, Docker/Podman install.
    
*   **Bastion role**:
    
    *   Nginx reverse proxy
        
    *   Fail2ban
        
    *   Let’s Encrypt certbot
        
*   **DNS role**: Pi-hole
    
*   **DB role**: Postgres (external volume on NAS)
    
*   **SSO role**: Authelia, integrated with proxy
    
*   **Webapps role**:
    
    *   App runtime (node, python, etc.)
        
    *   App-dashboard (SUI/Heimdall/Homepage)
        
    *   Container orchestration (Docker Compose, Portainer, or Nomad/K8s-lite later if needed)
        
*   **Media role**: Jellyfin
    
*   **Storage role**: Immich, Paperless, Nextcloud
    
*   **Compute role**: GPU drivers, CUDA libs, container runtime for AI
    
*   **Containerlab role**: Install Containerlab, templates for FRR topologies
    
*   **Misc role**: Placeholder
    

Run:

`ansible-playbook -i inventory/hosts.ini site.yml`

* * *

📂 **Repo Layout**
------------------

```
IaC/
├── ansible
│   ├── inventory
│   │   └── hosts.ini
│   ├── roles
│   │   ├── base
│   │   ├── bastion
│   │   ├── compute
│   │   ├── containerlab
│   │   ├── db
│   │   ├── dns
│   │   ├── media
│   │   ├── misc
│   │   ├── sso
│   │   ├── storage
│   │   └── webapps
│   └── site.yml
├── README.md
└── terraform
    └── proxmox
        ├── main.tf
        ├── outputs.tf
        ├── terraform.tfvars
        ├── variables.tf
        └── vm.tf.sample
```

* * *

🚦 Deployment Flow
------------------

1.  `terraform init && terraform apply` → Proxmox spins up all VMs with IPs + SSH keys.
    
2.  `ansible-playbook site.yml` → Configures base OS + services on each VM.
    
3.  Mount NAS volumes into relevant VMs (DB, storage, media).
    
4.  Verify ingress:
    
    *   Router → Bastion ID = 01`
        
    *   Bastion reverse proxy → Internal apps via DNS (Pi-hole resolves internal hostnames).
        

* * *

🔑 Notes
--------

*   Keep **state/data** (DB, Nextcloud, Jellyfin media) on NAS.
    
*   Keep **metadata/cache** on VM SSDs.
    
*   Secure Bastion (fail2ban, only entry point for SSH & HTTPS).
    
*   Version everything in Git → your lab becomes reproducible.
