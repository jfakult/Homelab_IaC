# Homelab IaC - context for AI assistants (and humans)

Read this first. It explains how the Proxmox box, the VMs, the network/DNS/SSO
plumbing, the Ansible repo and the git workflow fit together, plus the
traps that have already bitten us. Written 2026-09-21; things marked
**(verified live)** were checked against the running system that day, the rest
comes from the repo's config. **The repo and the live system win over this
file** - if they disagree, trust them and fix this doc.

`README.md` is the original design blueprint and is partly stale. This file supersedes it for "how things work today".
`ansible/docs/subdomains.md` is the walkthrough for adding a `<name>.fakult.net` service.

---

## 1. Big picture

```
Internet -> router (80/443/2222 only, per README) -> bastion (nginx reverse proxy, TLS)
                                                        |
        +----------+----------+---------+---------------+-----------+
        |          |          |         |               |           |
      sso        webapps    media     compute        monitoring     dns / db ...
   (Pocket-ID)  (journal)  (Jellyfin) (GPU: Ollama,   (Prom/Grafana/  (Pi-hole+Unbound,
                                       Whisper,        Loki/Alertmgr)  Postgres)
                                       Open WebUI)
All VMs live on one Proxmox host ("butlah") on 192.168.1.0/24, all joined to Tailscale.
```

- One physical Proxmox host, **butlah** (192.168.1.200, `butlah.fakult.net`), 11 Ubuntu 24.04 VMs (10 running; `storage` is deprecated and powered off).
- The Claude/AI session and the human both work **on butlah as root**, in
  `/root/IaC` (the git repo). butlah is the Ansible control node *and* the
  hypervisor. Editing is often via VS Code Remote-SSH.
- Everything is Docker Compose on the VMs. Config is rendered by Ansible
  (Jinja templates) into `/opt/<service>/` on each VM.
- Domain: `fakult.net`. Tailnet: `yak-anoles.ts.net`.

## 2. How to interact with the machines

### From butlah (this is where you run)
| Task | How |
|---|---|
| Run a command inside a VM | `qm guest exec <VMID> -- bash -c "..."` (QEMU guest agent; **runs as root inside the guest**, no SSH/sudo needed) |
| Get long-command result | `qm guest exec` returns `{"pid": N}` after ~30s; poll `qm guest exec-status <VMID> <pid>`. In status output `"exited": 0` means *still running* (it's a flag, not an exit code). |
| Write a file into a VM | No stdin support. Use `echo '<base64>' \| base64 -d \| sudo tee /path` inside `bash -c` |
| VM power/state | `qm list`, `qm status <id>`, `qm start/reboot <id>`, `qm config <id>` |
| Guest agent "not running" | Usually transient (VM busy/rebooting). Retry; check `qm status`. |
| Output shape | JSON with `out-data` / `err-data` / `exitcode`. Nonzero exit with empty `out-data` often = grep found nothing. |

**VMID = last octet of the IP** (bastion 201 = 192.168.1.201 ... monitoring 211). `9000` = cloud-init template.
Don't run `docker` commands on butlah expecting them to hit a VM - butlah has no
Docker daemon for these; always go through `qm guest exec <id>`.

### Ansible (how state changes get made)
```
cd ~/IaC/ansible
ansible-playbook -i inventory/hosts.ini site.yml [--limit <host>] [--tags <tag>] -J
```
- **`-J` = `--ask-vault-password`**. `group_vars/all/vault.yml` is encrypted, so
  *every* run prompts for the vault password. **An AI cannot run playbooks**
  (no vault password). Hand the owner the exact command and let them run it,
  then verify with read-only checks.
- The `ubuntu` user (remote_user, key-based SSH) has password-based `(ALL) ALL`
  sudo. How the become password is supplied isn't visible in plaintext config -
  ask the owner rather than guessing.
- `ansible.cfg`: `forks=12`, YAML results. Syntax check with
  `ansible-playbook -i inventory/hosts.ini site.yml --syntax-check | cat`
  (piping through `cat` avoids a non-blocking-IO quirk in some harnesses).
- SSH helper scripts at repo root: `start_ssh_agent.sh` (loads `~/.ssh/id_ed25519`),
  `gen_known_hosts.sh` (rebuilds `~/.ssh/known_hosts` from inventory names+IPs via
  `ssh-keyscan`), `gen_etc_hosts.sh` (prints /etc/hosts lines from inventory).

### Talking to services directly
LAN IPs work from butlah and any VM. Tailscale (100.x) also works. Use the
IP:port table below rather than public URLs when debugging.

## 3. Hosts and what runs where

Inventory: `ansible/inventory/hosts.ini` (**gitignored**, exists only on butlah).
Groups: `external` (bastion), `infra` (dns, db, sso, monitoring), `apps`
(webapps, media, compute), `lab` (containerlab, misc).

| VMID/host | IP | Runs (Compose project dir) | Notes |
|---|---|---|---|
| butlah (Proxmox) | .200 | no exporters (**verified live**: nothing on 9100/9113/8080) | **Not in ansible inventory.** `/etc/resolv.conf` lists 192.168.1.202 first (hand-managed). |
| 201 bastion | .201 | `rp-nginx` (/opt/gateway), certbot, cadvisor, exporters | Only public-facing VM. TLS termination + reverse proxy. nginx exists **only** as the container: the distro `nginx` package and `python3-certbot-nginx` were removed 2026-10-14 (certbot renews via `--webroot`); `nginx.service` is masked. `nginx-common` stays - it owns `/etc/nginx`, which rp-nginx bind-mounts. |
| 202 dns | .202 | `dns-pihole-1`, `dns-unbound-1` (/opt/dns), NordVPN client | Pi-hole web at `http://192.168.1.202/admin`. |
| 203 db | .203 | `pg-main` postgres:16 (/opt/postgres) | **One container** (`pg-main` is the container name, not a DB or role) holding one database per app (**verified live** 2026-10-18): `blinko` (journal, owned by role `blinko`) plus the default `postgres`/templates. Admin (superuser) role: **`butlah`**. Pocket-ID uses SQLite (`/opt/pocket-id/data/pocket-id.db`). `roles/db` (`tasks/main.yml`, tags `db`/`journal`) manages the container, `pg_hba.conf`, UFW and one role+DB per entry of `pg_databases` in `group_vars/infra.yml`; to add an app, add an entry (name, owner, password, allowed CIDRs). Images other than stock Postgres (e.g. Immich's VectorChord build) get their own container. |
| 204 sso | .204 | `pocket-id` (/opt/pocket-id), port 1411 | OIDC provider for everything. Database: the `pocketid` database on `pg-main` (`pocket_id_use_postgres: true`, migrated 2026-10-18 with Pocket-ID's own `export`/`import`; steps and the import pitfall in `ansible/docs/postgres-migrations.md`). `/opt/pocket-id/data` still holds the old `pocket-id.db` (rollback copy), the uploaded images, and `pre-postgres-export.zip` until they are cleaned up. Policy: every database that supports Postgres lives on the db VM; SQLite-only apps (Pi-hole, Jellyfin, the journal's vector store) stay local and are listed in `/root/backup/vm-dumps.json`. |
| 205 webapps | .205 | `blinko-website` (/opt/journal, :1111), `kiwix` (/opt/kiwix), `geo-proxy` (/opt/geo-proxy, :8091) | The AI journal. Image `ghcr.io/jfakult/blinko-journal:latest` built by GitHub Actions in the *separate* `jfakult/blinko-journal` repo. NAS mounts `/srv/www`, `/srv/nas`. `geo-proxy` is a reverse-geocoding proxy, LAN/Tailscale-only (not on a bastion subdomain). Also runs the non-Docker `webapp-*` systemd apps (resume etc., section 7.5). |
| 206 media | .206 | `jellyfin` (:8096) + exporters (/opt/jellyfin) | Media on NAS via NFS. Jellyfin SSO plugin uses Pocket-ID. |
| 207 storage | .207 | nothing | **Deprecated.** Was meant for Immich/Paperless/Nextcloud; those run on webapps (Postgres on the db VM). Powered off, autoboot off, 1 core / 512 MB, tagged `deprecated` in Proxmox (`started = false`, `on_boot = false` in `terraform.tfvars`); removed from the Ansible inventory; its disk (32 GB) and IP are kept. Delete the VM in Terraform to reclaim the disk. |
| 208 compute | .208 | `ollama` (:11434), `whisper` (:8000), `open-webui` (:3000), `searxng` (:8888) | RTX 4060 Ti 16GB passed through (hostpci0), 32GB RAM, 256GB disk. See section 7. |
| 209 containerlab | .209 | nothing | Placeholder. |
| 210 misc | .210 | nothing | Scratchpad. |
| 211 monitoring | .211 | prometheus :9090, grafana :3000, loki :3100, alertmanager :9093, blackbox :9115, `postfix-relay`, `speedtest-tracker` :3030, `smokeping` :3031 (all in /opt/monitoring) | speedtest-tracker is public at `speedtest.fakult.net` (the `speedtest` entry in `subdomains`; `fakult.net/speedtest` and `/quality` redirect there), protected by its own login. smokeping has no login and no bastion route: LAN/Tailscale only at `http://monitoring.yak-anoles.ts.net:3031/smokeping/`. Both are defined in the monitoring compose template; speedtest's `APP_KEY` is `vault_speedtest_app_key` and must stay the same value (it encrypts data in its DB; the "base64:" prefix is added if missing). Smokeping's `Targets`/`General` are rendered from `smokeping_targets` in `all/main.yml`. See section 7
| NAS | .199 | Unraid (NFS 4.2 shares under `/mnt/user/...`) | Separate physical box, not managed here. |

## 4. Network, DNS, TLS, SSO

### 4.1 DNS (most important - it has broken things several times)
```
VMs / butlah  ->  Pi-hole (192.168.1.202, dns VM, docker *host* network)
                     -> Unbound (127.0.0.1:5335, recursive)  -> root servers
```
- **Every VM's `/etc/resolv.conf`** is pushed by the `base` role from
  `roles/misc/templates/resolv.conf`: `192.168.1.202`, then `9.9.9.9`, `1.1.1.1`, `8.8.8.8`.
  Local records (**verified live** 2026-10-18): Pi-hole is v6 and ignores `/etc/dnsmasq.d`
  (`misc.etc_dnsmasq_d = false`), so `/opt/dns/etc-dnsmasq.d/10-static.conf` has no effect and
  `roles/dns/templates/static-hosts.conf.j2` is not rendered by the role. What actually answers
  is `dns.hosts` in the container's `/etc/pihole/pihole.toml` (hand-edited, **not in Ansible**):
  `sso.fakult.net` and bare `fakult.net` -> bastion, plus the `/etc/hosts` bind-mount for VM
  short names. Subdomains such as `chat.` and `speedtest.` are not listed, so inside the LAN
  they resolve through the public record to the home public IP (hairpin NAT through the router).
- **Tailscale must not manage DNS on VMs.** Tailscale's `accept-dns` defaults on and
  will overwrite `/etc/resolv.conf` ("generated by tailscale") with `100.100.100.100`
  (MagicDNS), which forwards nothing useful here. The `base` role runs
  `tailscale set --accept-dns=false` on every host (tag `tailscale`). Do not
  turn on the Tailscale admin console's tailnet-wide **"Override DNS servers"**:
  on 2026-09-17 that pointed *every* tailnet device (including butlah, and so the
  AI's own API connectivity) at Pi-hole and caused an outage; it was rolled back.
  Not fully root-caused. Keep it off.
- **The dns VM is special**: its own `/etc/resolv.conf` is `127.0.0.1` and is
  `chattr +i` (immutable) on purpose; `roles/dns` owns it and `base` skips it
  (`when: inventory_hostname != 'dns'`). It runs NordVPN (`nordlynx`) with Tailscale
  whitelisted; `systemd-resolved` is disabled there.
- **Pi-hole listening mode**: default `LOCAL` silently drops queries from
  non-local subnets (e.g. Tailscale 100.x). It was live-edited to `ALL` in the
  container's `/etc/pihole/pihole.toml` on 2026-09-17 - **that edit is not in
  Ansible** (see drift list).
- **Containers snapshot the host's resolver when they are *created*.** Changing
  host DNS does nothing for running containers; recreate them
  (`docker compose up -d --force-recreate --no-deps <svc>`). On 2026-09-21 this
  broke Open WebUI SSO ("email or password incorrect" was really
  `httpx.ConnectError: name resolution` to the token endpoint). Diagnose with
  `docker exec <c> grep ExtServers /etc/resolv.conf` (should list 192.168.1.202 first).
- `/etc/hosts` on VMs comes from `roles/misc/templates/hosts.j2` (short names +
  `<name>.fakult.net`) and **deliberately excludes `sso`**: `sso.fakult.net` must
  resolve via DNS to bastion (nginx, trusted Let's Encrypt cert), not straight to
  pocket-id's self-signed cert. `gen_etc_hosts.sh` mirrors this. Containers never read
  the host's `/etc/hosts` at all, so inside containers `sso.fakult.net` works only
  through Pi-hole.

### 4.2 Ingress, reverse proxy, TLS
- Public DNS (at the registrar, manual) -> home public IP -> router -> **bastion**.
  Inside the LAN, Pi-hole answers `*.fakult.net` with bastion's IP too (split-horizon-ish):
  LAN clients and containers hit the same nginx + cert as the internet.
- bastion runs nginx in Docker (`rp-nginx`, /opt/gateway). Config is rendered by the
  `bastion` role: `templates/nginx/**` pushed 1:1, except the two per-subdomain
  templates rendered by `render_subdomains.yml`. **Never hand-edit
  `/etc/nginx/conf.d/subdomains/`** - regenerated every run.
- Certificates: Let's Encrypt via certbot (HTTP-01, one `--cert-name` per
  subdomain, renew timer in `roles/bastion/files/`). `local_pki` role / `pki-out/`
  (gitignored) is the mkcert side for local certs.
- Two URL styles: **path prefixes** on `fakult.net` (`/journal` -> webapps:1111,
  `/jellyfin` -> media:8096, kiwix) and **subdomains** for apps that can't live under a
  path (`sso.fakult.net` -> sso:1411, `chat.fakult.net` -> compute:3000).
  Add a subdomain by adding one entry to `subdomains` in
  `inventory/group_vars/all/main.yml` - see `ansible/docs/subdomains.md`.

### 4.3 SSO (Pocket-ID, OIDC)
- Issuer `https://sso.fakult.net`. Clients: blinko-journal (webapps), Open WebUI
  (compute), Jellyfin. **Clients are created by hand in the Pocket-ID UI** (no API);
  client id/secret go in the vault.
- The browser flow works, but the **app backend also calls the issuer server-side**
  (token exchange, discovery) - so each container must resolve and reach
  `sso.fakult.net` (-> bastion) over the LAN. Container DNS problems therefore
  show up as bogus "login failed" errors.
- Open WebUI role mapping: Pocket-ID group named by `open_webui_admin_group`
  (`admin`) -> Open WebUI admin, re-evaluated every login. Local email/password
  login stays enabled as a break-glass path.

### 4.4 Tailscale
Installed by the `base` role on every VM (pre-shared `tailscale_auth_key`, hostname =
inventory name). Used for ad-hoc/remote access (e.g. a DB client to Postgres via
`pg_hba.conf` + UFW rule for 100.64.0.0/10). Container egress rules treat LAN
(192.168.1.0/24) and Tailscale (100.64.0.0/10) as "allowed".

### 4.5 Container network firewalls (iptables `DOCKER-USER`)
- `compute-lan` (172.30.0.0/24, Ollama/Whisper/Open WebUI): LAN + Tailscale only,
  **WAN dropped**. `/opt/toggle-wan-egress.sh open|close` (on compute) temporarily
  opens WAN for `ollama pull` / new Whisper models; it is intentionally not persisted
  when open. searxng is on a different network and has normal egress (it must
  search the internet).
- `blinko-egress` (webapps): LAN + Tailscale accept rules, **WAN deliberately left
  open** (the journal calls `api.unstructured.io`; that host currently NXDOMAINs
  anyway - unresolved app-side issue).

### 4.6 Email / alerting
Alertmanager -> `postfix-relay` container (same compose network, unauthenticated
:25) -> `smtp.gmail.com:587` using a Gmail **App Password** (`vault_smtp_relay_password`,
requires 2-Step Verification). Alerts go to the owner's Gmail. Direct-to-MX from a
home IP was rejected as unreliable; Gmail was a deliberate choice after weighing privacy.

## 5. Ansible layout

```
ansible/
  site.yml                    # play order below
  inventory/hosts.ini         # gitignored
  inventory/group_vars/
    all/main.yml              # shared: domain, subdomains list, monitoring, smtp
    all/vault.yml             # ENCRYPTED, tracked; vault_* secrets
    infra.yml external.yml apps.yml   # per-group vars (apps.yml = AI stack model pins etc.)
  roles/<name>/{tasks,templates,files,handlers}
  docs/subdomains.md
```
- **`site.yml` order**: `base` (all hosts; tags `base`,`tested`) -> `local_pki` (localhost)
  -> sso -> bastion -> dns -> media -> db (**tags `db`, `journal`**)
  -> webapps -> compute -> monitoring. The webapps/compute/monitoring plays
  themselves are untagged.
- **Targeting**: `--limit <host>` for one VM; `--tags` for slices. Tags in use:
  `base tested tailscale hostname nginx certbot journal kiwix ollama whisper chat`.
  Untagged tasks do **not** run when you pass `--tags`, so a tag-only run can skip
  pre-steps. Monitoring has no tags: use `--limit monitoring`.
- **Vars**: `group_vars` don't cross inventory groups. Shared things (e.g.
  `subdomains`, used by both dns[infra] and bastion[external]) live in `all/main.yml`.
  Secrets: the plain var references `{{ vault_x }}`; edit the vault with
  `ansible-vault edit inventory/group_vars/all/vault.yml` (its git diff always looks
  like a full rewrite - that's normal).
- **Rendering conventions**: Jinja `.j2` templates; compose files land at
  `/opt/<svc>/docker-compose.yml`, secrets in `/opt/<svc>/.env`. `copy` module only
  auto-searches `files/`, not `tasks/templates/` - binary assets (the FakChat PNGs)
  are copied with an explicit `{{ role_path }}/tasks/templates/...` src.
- **A changed bind-mounted config file does not recreate the container** (compose
  sees no service-definition change): after a config-only change (alertmanager.yml,
  loki-config.yml, ...) restart the container yourself
  (`docker compose restart <svc>`).
- Prefer idempotent, tag-scoped changes; deploys for plain image updates of the
  journal are just `/opt/journal/full_pull.sh` on webapps (pull, force-recreate,
  `docker image prune -f` - old images otherwise fill the disk).

## 6. Git

- Repo root **`/root/IaC`** (not `ansible/`). Remote `git@github.com:jfakult/Homelab_IaC.git`,
  branch `master`, commits authored as `root@butlah.fakult.net`.
- Style: short imperative subject describing the fix/feature + a body explaining the *why*
  (incident, constraint). Commit trailer per the harness config
  (currently `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`).
  Make new commits; don't amend or force-push unless the owner asks. **Never commit or push
  unless asked.**
- **`.gitignore` traps** (root `.gitignore`): `hosts.ini`, `pki-out/`, `*.conf.j2`,
  `*.env*`, `snippets/*.j2`, `*.vault.yml`, `*.tfstate*`, `terraform.tfvars`.
  Many `.conf.j2` files were force-added (`git add -f`) and are tracked, but these
  templates **exist on disk yet are untracked/ignored (unversioned!)** as of 2026-09-21:
  `nginx/conf.d/{metrics,subdomain}.conf.j2`, most of `nginx/snippets/*.j2`
  (ai, dns, journal, kiwix, monitoring, nodeJS_servers, subdomain-redirects),
  `nginx_exporter.env.j2`, `dns/cadvisor.env.j2`, `dns/pihole_exporter.env.j2`,
  `media/{cadvisor,jellyfin_exporter}.env.j2`, `webapps/.../journal.env.j2`,
  `compute/.../needrestart-containerd-exclude.conf.j2`. When you create or edit a
  template matching those patterns, check `git status --ignored` and use `git add -f`
  if it should be versioned.
- The journal app's own source lives in a different repo (`jfakult/blinko-journal`);
  infra-side sessions only see its built image. App bugs (missing imports, bad Zod
  schemas, doubled `/api` URLs, prompt problems) get handed back to the app repo.

## 7. Service notes

### 7.1 blinko-journal (webapps, "the journal")
- Node app + Mastra agents; Postgres on the db VM (`DATABASE_URL` in
  `/opt/journal/.env`, rendered from `journal.env.j2`). Data dir bind-mounted from
  `/home/ubuntu/blinko-journal/.blinko`.
- AI wiring: `OLLAMA_BASE_URL` = compute's Ollama **with `/api` suffix** (the
  `ollama-ai-provider` library needs it; Open WebUI's client wants it bare - same
  `ollama_base_url` var, suffix added only in `journal.env.j2`),
  `OLLAMA_CHAT_MODEL`, `OLLAMA_POST_PROCESSING_MODEL`, embedding/vision models,
  `WHISPER_BASE_URL`. Task/audit logs: Postgres table `"aiTaskLog"` (full per-agent
  call input/output; more complete than container logs).
- Prisma migrations run at container start; `full_pull.sh` is enough for new
  migrations. Tables must be **owned** by role `blinko` (GRANT isn't enough for DDL).
- Docker log lines over ~64KB get truncated; to capture a huge stack trace redirect
  the app's output to a file inside the container and `docker cp` it out.

### 7.2 geo-proxy (webapps)
- `/opt/geo-proxy`: `python:3.12-alpine` + a stdlib-only script bind-mounted
  from the host (`geo_proxy_app.py`, rendered by `roles/webapps`) - no
  Dockerfile/build step. `GET /reverse?lat=&lon=` calls Nominatim/OSM
  (`nominatim.openstreetmap.org`) and returns place/name data for coords;
  `GET /health` for the container healthcheck.
- **Reachable from LAN + Tailscale only, by topology, not firewall rules**:
  it's on the default Docker network (no custom `firewall.yml` - unlike
  `blinko-egress`/`compute-lan`, it needs normal open egress to reach
  Nominatim, so there's nothing to restrict outbound), and this host has no
  WAN-facing interface or router port-forward for 8091, so nothing on the
  internet can reach it. Not in `subdomains`/bastion/`prometheus_targets`
  on purpose.
- Self-throttles to Nominatim's usage policy (max ~1 req/sec) and caches
  recent lookups in memory (single-threaded `HTTPServer`, so the throttle is
  enforced by construction). `CONTACT_EMAIL` env (reuses
  `smtp_relay_username`) is the identifying contact Nominatim's usage policy
  requires - see `geo_proxy_contact_email`/`geo_proxy_port` in
  `all/main.yml`. No vault entry: Nominatim needs no API key.
- Deploy: `ansible-playbook -i inventory/hosts.ini site.yml --tags geo-proxy -J`
  (task tag, no `--limit` needed - only touches the webapps host).

### 7.3 AI stack (compute)
- Model pins live in `inventory/group_vars/apps.yml` (single source of truth for
  both compose roles and webapps): `ollama_chat_model_base` / `ollama_chat_model` (chat,
  currently `gemma4:e4b`), `ollama_post_processing_model` (`qwen3:1.7b`, also Open WebUI's Local
  Task Model), `ollama_embedding_model` (`nomic-embed-text`), `ollama_vision_model` (`llava`),
  plus `ollama_extra_models` (empty; add a line to try another). The compute play pulls only
  models that are **not already installed** (`ollama list`), so a moved upstream tag is never
  re-downloaded silently; refresh one on purpose with `-e ollama_force_pull=true`. There is no
  `num_predict` cap: Ollama's default is unbounded, and an uncapped qwen3.5:9b generation once
  ran 40k+ tokens for ~2 hours (see "Killing a runaway Ollama generation" below).
  Ollama env: `OLLAMA_CONTEXT_LENGTH`, `OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_KEEP_ALIVE` in the
  ollama compose template. Whisper: `Systran/faster-whisper-medium` only.
- VRAM is the real constraint (16GB shared with Whisper): e.g. gemma4:e4b is 9.6GB on
  disk despite its "small" name. Raising `MAX_LOADED_MODELS` doesn't help if VRAM
  can't hold the models; Ollama will evict.
- **GPU self-healing** (all in the compute role): GPU access silently breaks (CPU
  fallback, no error) when dockerd *or containerd* restarts, when the NVIDIA CDI
  spec `/etc/cdi/nvidia.yaml` is missing/stale, or when the driver/kernel module
  versions mismatch. Guards, all built on `/usr/local/sbin/gpu-heal.sh`, which finds
  **every GPU container automatically** (any container with an NVIDIA device request
  or the nvidia runtime; no labels, no per-service lists), so a new GPU service is
  covered by just using `deploy.resources.reservations.devices: driver: nvidia` in its compose:
  `gpu-containers-recreate.service` (regenerates the CDI spec and runs `gpu-heal.sh recreate`,
  a `--force-recreate --no-deps` of each GPU compose service, whenever docker/containerd
  restart), and the `gpu-health-check` timer (`gpu-heal.sh check`: `nvidia-smi` probe inside
  each GPU container plus a log scan for CUDA/NVML failure signatures; self-heals, reboots
  after repeated failures). Also: NVIDIA packages blacklisted from
  unattended-upgrades, `needrestart` told not to bounce containerd. Check GPU use with
  `curl localhost:11434/api/ps` (`size_vram` must be > 0), `nvidia-smi`, and
  `gpu-heal.sh list|check`.
  A plain `docker restart` of a GPU container after a daemon restart does **not** fix it; recreate.
- Killing a runaway Ollama generation: `ollama stop` only updates bookkeeping.
  Find the `llama-server` PID with `docker top ollama` and `kill -9` it **on the VM**
  (host PID, not via `docker exec`). Ollama respawns a runner on the next request.
- Whisper = `speaches`, model `Systran/faster-whisper-medium`. It auto-loads models
  on request. **`DELETE /v1/models/<id>` deletes the model from disk**, not just memory
  (a later request 404s "not installed locally"; re-download with `POST /v1/models/<id>`).
  TTL env is `WHISPER__TTL` (nested pydantic prefix; `STT_MODEL_TTL` was silently ignored).
- Open WebUI (`chat.fakult.net`): branded "FakChat" (`WEBUI_NAME` always renders
  "FakChat (Open WebUI)" - hardcoded license suffix). Logos are bind-mounted over
  `/app/build/static/*` from `/opt/open-webui/branding/`. Several settings are
  DB-stored and only seeded by env on a fresh install (e.g. web search toggle) -
  change those in the admin UI.
- searxng feeds Open WebUI web search over the shared `websearch` Docker network.

### 7.4 Monitoring (monitoring VM)
- Data under `/opt/monitoring/{prometheus,prometheus-data,grafana,loki,loki-data,alertmanager}`.
  Ownership matters: loki-data must be uid **10001**, grafana **472**, prometheus **65534**
  (loki crash-looped 5 weeks on wrong ownership + missing `compactor.working_directory`
  + missing `ingester.wal.dir`). Prometheus scrape targets are the
  `prometheus_targets` map in `all/main.yml`.
- Docker log size is capped host-wide: `roles/misc/tasks/docker_daemon_defaults.yml`
  merges `log-driver: json-file` and `log-opts` (`docker_log_max_size`/`docker_log_max_file`
  in `all/main.yml`, 10m x 3) into each host's `/etc/docker/daemon.json`, keeping any other
  keys (compute's nvidia runtime). It never restarts Docker. A crash loop once filled the
  monitoring VM's 10GB disk with uncapped logs.
  - Defaults only reach a container when it is (re)created after Docker has re-read the
    file: run `ansible-playbook -i inventory/hosts.ini docker_logs_apply.yml --limit <host> -J`
    (restarts Docker, recreates every compose project; one host at a time, `--limit` required).
  - Tune one host: set the vars in `host_vars/<host>.yml`. Tune one container: a `logging:`
    block in its compose file always wins over the daemon default.
- Alertmanager treats missing SMTP config as **fatal** at startup (it crash-loops silently).

### 7.5 Non-Docker webapps (webapps VM, systemd, `webappctl`)
- Non-Docker apps (resume, sunset, link_shortener, hugo, ...) live on the VM's
  **local disk** in `/srv/webapps/<app>/`, each with `start.sh` and `stop.sh`.
  They are not in git or Ansible; apps are added by hand.
- `/srv/generate_web_daemons.sh` (run by `/srv/webappctl.sh scan`) writes
  `webapp-<app>.service` units (`WorkingDirectory=/srv/webapps/<app>`,
  `Restart=always`, root) and skips folders whose names start with `_`.
  `webappctl.sh start|stop|restart|status [app]` wraps `systemctl`. All three
  scripts come from `roles/webapps/tasks/files/`.
- Bastion routes `/resume` to `:3010`, `/l` to `:8100`, `/sunset` to `:7010`
  (`snippets/nodeJS_servers.conf.j2`).
- **Backup mirror:** `webapps-nas-sync.timer` (every 3h) rsyncs `/srv/webapps/`
  one-way to `/srv/www/_webapps/` (NAS `Server_WebappsCache`). Local wins and
  nothing is deleted on the NAS. `/srv/www/_webapps/context.md` documents it.
  `/srv/www` is bastion's static web root, so `nginx.conf.j2` returns 404 for
  `^~ /_webapps`. Deploy: `--tags webapps-sync` (webapps) and
  `--tags nginx --limit bastion`.
- Bastion's own `/srv/webapps` is unused.
  11 of the 19 units are in restart loops (for example, `stocks`:
  `su: user butlah does not exist`). `webapp-archive` is bogus: the scan picks
  up its own `archive/` folder.

### 7.5a jobpipe (webapps, nightly)
- `jobpipe.timer` runs `/srv/www/jobs/jobpipe/run_all.sh` as `ubuntu` (cwd = jobpipe dir)
  every night at 04:00 America/New_York (the VM clock is UTC; the zone in `OnCalendar`
  handles DST). The script and its venv live on the NAS share, not in git.
  Output goes to `journalctl -u jobpipe`. Deploy: `--tags jobpipe`.

### 7.6 Kiwix (webapps) and stale NAS handles
- `/opt/kiwix`, served at `fakult.net/wikipedia` (:3090). Zims are on the NAS
  under `/srv/nas/kiwix/zim` and `/srv/www/kiwix/zim`. The container binds the
  share **roots** read-only (`/mnt/nas`, `/mnt/www`) and rebuilds
  `/tmp/library.xml` on every start. `library.xml` in
  `/srv/www/kiwix/zim` is ignored.
- Why the share roots: Unraid (`shfs`, `fuse_remember`) drops NFS handles.
  The host re-resolves paths and recovers, but a bind of a NAS *subdirectory*
  stays `Stale file handle` / "error 116 opening file" until the container
  restarts (hit on 2026-09-23).
- Binding the roots does **not** protect the zim files kiwix holds open. On
  2026-09-23, reads of an open zim failed within about 5 min of a fresh start
  (`Cannot mmap ... : Stale file handle` in the logs; some pages 404/500,
  others fine). The real fix is Unraid `fuse_remember=-1`.
- Safety net: `docker-autoheal.timer` (every 2 min,
  `/usr/local/sbin/docker-autoheal.sh`) restarts containers labelled
  `autoheal=true` when either
  - Docker reports them unhealthy (kiwix's healthcheck fetches
    `raw/<book>/meta/Title`, which only catches a dead mount, because
    metadata is served from memory), or
  - their `autoheal.log_pattern` label (kiwix: `Stale file handle`) matches
    the log output since the last run.

  It doesn't restart a container when a bind source is unreadable on the host
  too (in that case the NAS is down).
- Deploy: `--tags kiwix`.

### 7.7 NAS resilience (bastion, webapps, media) and the crash drill
Added 2026-10-14 after a NAS reboot. Shared task `roles/misc/tasks/nas_resilience.yml`
(tag `nas`; webapps also under `kiwix`), configured per host by `/etc/nas-resilience.conf`
(`NAS_MOUNTS`, `NAS_WAIT_SECONDS=180`):
- `nas-wait.service` + `docker.service.d/10-nas-order.conf`: Docker starts after a
  **bounded** wait for the NFS mounts. Deliberately `Wants`, not `Requires`/`RequiresMountsFor`:
  a hard dependency would keep *every* container on the VM (bastion = everything public)
  down while the NAS is down.
- `nas-watchdog.timer` (1m): if a mount is unreadable and the NAS answers on 2049,
  umount+remount; for each container bind-mounting under a NAS path, compare
  `st_dev:inode` host vs `/proc/<pid>/root<dest>` and restart on mismatch (stale handle,
  or container started on the empty mountpoint). 10 min per-container cooldown.
  NAS down = log only. `nas-watchdog.sh --check` = report only.
- `docker-autoheal` (moved to `roles/misc/files`) now also runs on bastion and media.
  Labelled `autoheal=true`: kiwix, rp-nginx, jellyfin. Their healthchecks now also
  require the NAS-backed dir to list non-empty.
- **Crash drill:** `/root/IaC/nas_crash_drill.sh [--write] [--fix]` on butlah. Read-only
  by default; exit status = problems. Run it after any NAS reboot.
- Not covered: `jobpipe` / `webapps-nas-sync` just fail one run and retry on schedule.
- Unraid `fuse_remember=-1` was set 2026-10-14; exports are no_root_squash/no_all_squash.
  The `/srv/www/html/share` (Public) fstab entry is intentionally not mounted.

## 8. Provisioning (below Ansible)
`terraform/proxmox/` (bpg/proxmox provider) creates the VMs from cloud-init template
`9000`; `goldenize.sh` bakes `qemu-guest-agent` and basic tools into the cloud image;
`update_cloud_init.sh -v <VMID> [-g] [-d]` regenerates a VM's cloud-init seed.
`terraform.tfvars`/state are gitignored. Static IPs come from cloud-init `ipconfig0`;
there is no Proxmox-level nameserver setting - DNS comes from Ansible.

## 9. Working agreements (the owner's stated preferences)
1. **Ansible first.** Config/state changes go through the repo; the AI edits the
   templates and hands over the exact `ansible-playbook ... -J` command. Read-only
   checks via `qm guest exec` are always fine. If you live-patch during an incident
   (owner asked, disk full, etc.), say so and mirror the change into the role so
   nothing drifts.
2. Ask before destructive, hard-to-reverse or shared-state actions; state the blast
   radius. "Don't make any changes" means strictly read-only.
3. Verify claims against the live system and correct wrong premises with evidence
   (this has been welcomed). Prefer root cause over a workaround.
4. **DNS/network changes can cut off the AI itself** (butlah resolves via Pi-hole; the
   AI's API traffic needs DNS). Change one thing, verify, keep a rollback ready.
5. Commit only when asked; never force-push; don't include secrets.
6. Give a short summary and the next command; the owner will run deploys.
7. **Databases live on the db VM (203) whenever the app can use Postgres.** Do not add a
   SQLite file, a Postgres/MySQL container or a vector DB to an app VM. Instead:
   - Default: add an entry to `pg_databases` in `ansible/inventory/group_vars/infra.yml`
     (name, owner, password via a new `vault_*` key, allowed CIDRs). `roles/db` then creates the
     role + database in `pg-main`, the `pg_hba.conf` line and the UFW rule; point the app at
     `192.168.1.203:5432` (a connection URL or `DB_*` env vars, per the app).
   - If the app needs something stock Postgres does not have (extensions such as VectorChord or
     pgvector, a different major version), run **another Postgres container on the db VM** (own dir
     under `/opt`, own port, own volume), never on the app VM. The first example is Immich's.
   - Moving an existing SQLite app over: follow `ansible/docs/postgres-migrations.md` (the app creates
     the schema on an empty Postgres database, then `scripts/sqlite_to_pg.py` copies the data; rehearse
     on a scratch Postgres first).
   - Add the new database to the dump list: it is covered automatically if it is in an existing Postgres
     container on 203 (`pg_dumpall`); a new container needs its own `postgres` entry in
     `/root/backup/vm-dumps.json`.
   - Only when an app genuinely cannot use Postgres (Pi-hole, Jellyfin, the journal's vector store) does
     its data stay on the app VM. List it as a `sqlite` entry in `vm-dumps.json` so it is backed up, and
     never put a SQLite file on NFS/NAS.
   - Postgres never lives on a network share, and the app's own data (media, uploads) may.
   - **Never delete the original SQLite files, nightly `.bak` copies or export ZIPs of a migrated app**
     as part of cleanup; they are the rollback. Only the owner decides when they go.

## 10. Known drift / open items (as of 2026-09-21)
- Pi-hole `listeningMode=ALL` set live in the container volume, not in Ansible.
- Pi-hole `dns.hosts` (local DNS records) is hand-edited in `pihole.toml`, not in Ansible; new `subdomains` entries do not get a local record (see 4.1). Declaring them with `FTLCONF_dns_hosts` in the dns compose file would fix both.
- `/etc/systemd/resolved.conf.d/fallback-dns.conf` created live on monitoring (harmless).
- Uncommitted work in the tree: FakChat branding, loki config fixes, base-role
  DNS/tailscale fix, postfix-relay + alertmanager SMTP config, vault update.
- Older monitoring containers use the host stub resolver (127.0.0.53), newer ones use
  Pi-hole; harmless but inconsistent. `ollama`/`whisper` still carry the old
  MagicDNS upstream until next recreate (they need no DNS).
- `pihole_api_token: "VAULT_PIHOLE_TOKEN"` in `all/main.yml` is a placeholder.
- **`prometheus_targets` in `all/main.yml` is stale**: it scrapes `192.168.1.200` (labelled
  "Bastion") for node/nginx/cadvisor, but butlah runs no exporters - bastion (.201)
  does. Expect some Prometheus targets to be down/mislabelled until it's updated.
- The dns role calls NordVPN + `tailscale set --accept-dns=false`; changing that role
  risks the DNS VM's own resolution - test carefully.
- Tailscale admin console still has the Pi-hole global nameserver entry; override is OFF.

## 10a. TODO (short list)
- **Pocket-ID leftovers** (after it has run cleanly on Postgres for a day): remove the `204` entry from `/root/backup/vm-dumps.json` (the db VM dump covers it now); delete `/opt/pocket-id/data/pocket-id.db*` and `pre-postgres-export.zip` on the SSO VM, and `/root/backup/pocket-id-pre-postgres/` on butlah (all hold secrets).
- **SQLite -> Postgres moves still to do** (runbook: `ansible/docs/postgres-migrations.md`): speedtest-tracker and Grafana (monitoring VM), Open WebUI (compute; its chroma vector store stays local). Rehearsed and verified; code is in place behind the `*_use_postgres` flags. Needs four vault keys (see the runbook). Afterwards remove their `sqlite` entries from `vm-dumps.json`.
- **Monitoring audit:** stale `prometheus_targets` (scrapes .200 for exporters butlah does not run; node exporters missing on media and monitoring), alert rules and Alertmanager routing, Grafana dashboards (Grafana admin password is still `changeme` in the monitoring compose), decide what to alert on for Immich/Postgres/GPU/NAS.

## 11. Cheat sheet
```
# health of a VM's containers
qm guest exec 208 -- bash -c "docker ps -a --format '{{.Names}}: {{.Status}}'"
# logs
qm guest exec 205 -- bash -c "docker logs blinko-website --tail 100 --since 10m 2>&1"
# is the GPU really used?
qm guest exec 208 -- curl -s http://localhost:11434/api/ps
# what DNS is a container really using?
qm guest exec <id> -- bash -c "docker exec <container> grep ExtServers /etc/resolv.conf"
# who resolves what
qm guest exec <id> -- dig @192.168.1.202 sso.fakult.net +short
# deploy slices (owner runs these)
ansible-playbook -i inventory/hosts.ini site.yml --tags base -J
ansible-playbook -i inventory/hosts.ini site.yml --limit monitoring -J
ansible-playbook -i inventory/hosts.ini site.yml --tags journal -J     # db provision + webapps journal
ansible-playbook -i inventory/hosts.ini site.yml --tags geo-proxy -J   # reverse-geocoding proxy on webapps
ansible-playbook -i inventory/hosts.ini site.yml --tags ollama,whisper,chat --limit compute -J
ansible-playbook -i inventory/hosts.ini site.yml --tags nginx,certbot --limit bastion -J
```

## 12. Backups and restore (built 2026-10-15, **verified live** 2026-10-16)

### 12.1 In plain words
- **Every night at 02:00 Proxmox backs up all VM disks to PBS.** PBS is a VM that runs on the Unraid box and stores the backups on an Unraid array disk. Only changed data is sent, so it takes about 2 minutes.
- **Just before each VM is snapshotted, a hook makes a fresh copy of that VM's databases** (Postgres, SQLite) inside the VM, so the snapshot has a clean copy and not only a "pulled the plug" one.
- **Once a day, butlah backs up its own config and Unraid's config** with restic. The Proxmox config goes to the Unraid NAS share; the Unraid config is pulled to butlah and mirrored to the share.
- **An hourly watchdog emails you** if something is stale or failing.
- **Your laptop** pulls the config copies from the NAS share (12.5).
- Everything is started by **butlah**: the Proxmox scheduler (02:00 VM job) and three systemd timers. Nothing runs by itself on the VMs or on Unraid (Unraid only answers butlah's read-only SSH requests). No cron.

All scripts live in **`/root/backup` on butlah** (not in this repo: they cover the whole host, not just IaC; not committed). Units are in `/etc/systemd/system`. **What gets dumped is declared in `/root/backup/vm-dumps.json`** (one entry per VMID: `sqlite` files and `postgres` containers; `"enabled": false` skips one). Add a database there, run `lib/gen_vm_dump.py --check`, then `vzdump-hook.sh --run <vmid>`; no script editing. Every script has `-h`, `--estimate` (dry run) and `--watch` (follows its journal). Each writes `/var/lib/<name>/{last_success,last_summary,last_failure,backoff_until}`; after a failure it waits 15 min, then 1 h, 4 h, 6 h before trying again. restic repos have an empty password (`restic --insecure-no-password -r <repo> ...`).

### 12.2 Diagrams

**A. VM disks and database dumps (02:00 every night)**
```
  INVOKER: Proxmox job scheduler, 02:00 daily  (job backup-c87aa9a6-b031, all guests, one after another)
      |
      v
 +-- BUTLAH (Proxmox host, 192.168.1.200) ------------------------------------------------------+
 |   vzdump  --- before each VM ---> /root/backup/vzdump-hook.sh   (set by "script:" in          |
 |                                       |                          /etc/vzdump.conf)           |
 |                                       | qm guest exec <vmid>    (QEMU guest agent, host->VM) |
 +---------------------------------------|------------------------------------------------------+
                                         v   sends a script generated from vm-dumps.json into the VM
 +-- THE VM (only 202 203 204 205 206 208 211 have a dump) -------------------------------------+
 |   runs as root inside the VM:                                                                 |
 |     203 db:   docker exec pg-main pg_dumpall | gzip   (keeps newest 3)                       |
 |     others:   SQLite online copy (python3 sqlite3 backup API) -> one rolling <name>.bak       |
 |                  |                                                                            |
 |                  +--> /var/backups/vm-dumps/   (on the VM's own disk)                         |
 +---------------------------------------|------------------------------------------------------+
                                         v   vzdump freezes the VM filesystem and snapshots the disk
 butlah ====== changed disk blocks over the LAN (1 Gbps) ======> PBS VM 192.168.1.198
                                                                  (a VM on the Unraid box)
                                                      datastore "pbs_backup" = vdisk on array disk3
                                                      PBS prunes old snapshots on its own schedule
```
If a dump fails the hook sends an alert and the VM backup carries on (the hook always exits 0).

**B. Config backups (systemd timers on butlah, due about once a day after 03:00)**
```
  INVOKER: systemd timers on butlah, wake every 15 min, the script decides if a run is due
  host-config-backup.timer   --> host-config-backup.service   --> /root/backup/host-config-backup.sh --if-due
  unraid-config-backup.timer --> unraid-config-backup.service --> /root/backup/unraid-config-backup.sh --if-due

 host-config-backup.sh  (runs on butlah)                    unraid-config-backup.sh  (runs on butlah)
 1 copy /etc/pve, network, cron, units, /root,              1 ssh to Unraid with the READ-ONLY key
   IaC, SSH keys, package lists -> staging folder              Unraid runs ONLY backup-gate.sh:
 2 mount Unraid NFS share "Backup" (for this run only)          rsync-read of /boot/config,
 3 restic backup  --> Backup/Butlah/proxmox-config              plugin list, VM definitions
 4 tarball        --> Backup/Butlah/proxmox-config-tarballs/ 2 files land in /var/lib/unraid-config-backup/mirror
                      and /srv/backup/export/                3 restic backup --> /srv/backup/unraid-config  (butlah)
 5 restic copy    --> /srv/backup/proxmox-config (butlah)   4 tarball --> /srv/backup/export/ and share
 6 unmount the share                                         5 mount share, restic copy --> Backup/Butlah/unraid-config,
                                                               unmount
```

**C. Where the copies end up**
```
        BUTLAH (.200)                     UNRAID NAS (.199)                         LAPTOP (Framework)
   /srv/backup/                      +-- array --------------------------+
    |- proxmox-config  (restic)      |  PBS VM (.198) + its datastore    |      ~/bin/restic/restic_backup.sh
    |- unraid-config   (restic)      |  share  Backup/                   |       |- backs up the laptop
    |- export/                       |    |- Butlah/                     |       |     --> Backup/Framework
    |    *-latest.tar.gz, SHA256SUMS |    |    |- proxmox-config  (restic)  <-- written by butlah (diagram B)
    '- (nothing else)                |    |    |- unraid-config   (restic)  <-- written by butlah (diagram B)
                                     |    |    |- *-tarballs/            |  '- pulls from the NAS share
                                     |    |    '- pbs-vdisk/ (PBS data)   |        Backup/{unraid_appdata,
                                     |    '- Framework/  (laptop backups) |         unraid_config, proxmox_config}
                                     +-----------------------------------+        (see 12.5: names differ)

   ALERTS:  scripts on butlah --POST--> Alertmanager (VM 211, :9093) --> postfix-relay --> Gmail --> you
```

### 12.3 Who calls what

| Invoker | What it starts | Runs on | What it does |
|---|---|---|---|
| Proxmox job scheduler, 02:00 | `vzdump` (job `backup-c87aa9a6-b031`) | butlah | Snapshots every VM and sends it to PBS |
| `vzdump`, before each VM | `/root/backup/vzdump-hook.sh` (+ `lib/gen_vm_dump.py`, `vm-dumps.json`) | hook on butlah, dump inside the VM | Makes the database dumps (diagram A) |
| `host-config-backup.timer` (15 min) | `host-config-backup.sh --if-due` | butlah | Proxmox config -> restic (diagram B) |
| `unraid-config-backup.timer` (15 min) | `unraid-config-backup.sh --if-due` | butlah (reads Unraid over SSH) | Unraid config -> restic (diagram B) |
| `backup-check.timer` (hourly) | `backup-check.sh` | butlah | Emails you if a guest has no PBS backup for 2 days, a config backup is stale for 2 days, PBS storage is over 80%, or a guest has over 30 snapshots (pruning not happening) |
| PBS (its own scheduler, set on the PBS VM) | prune and garbage collection | PBS VM | Keeps 7 daily / 4 weekly / 6 monthly. PVE's storage entry is `keep-all`, so only PBS deletes old backups |
| `restic_backup.sh` (laptop) | backup of the laptop, pull from the NAS | laptop | Section 12.5 |

Also: `ALERT_DRY=1` or `backup-check.sh --dry-run` prints alerts instead of sending. PVE's built-in notification targets only go to mail-to-root (undeliverable), so they are not used.

### 12.4 Copies, and what is NOT covered

| What | Copy 1 (live) | Copy 2 | Copy 3 |
|---|---|---|---|
| VM disks | Proxmox (local-lvm) | PBS datastore on Unraid | none yet |
| Databases | inside the VM | inside every PBS snapshot of that VM | none yet |
| Proxmox config | butlah | restic on the Unraid share | `/srv/backup/proxmox-config` on butlah, laptop |
| Unraid config | Unraid flash | `/srv/backup/unraid-config` on butlah | share mirror, laptop (Unraid also has its own flash backup) |

Offsite: none yet. **Decision (2026-10-17): the NAS data itself (media, photos, anything on Unraid shares) not being backed up is accepted for now.** Parity only; the plan is to add a cloud backup eventually. Do not treat it as an oversight or nag about it, but keep it in mind when sizing new NAS-resident data (e.g. a photo library). **Not backed up:** the PBS VM itself (its OS disk, users, tokens; the runbook explains the rebuild), the Unraid OS images and `/boot/syslinux` (plugin packages are re-downloaded from the `.plg` files), media and other NAS data. `/mnt/user/appdata` on Unraid is empty today; if you add containers with data, an appdata backup has to be added. Secrets (`/etc/pve/priv`, SSH keys, duckdns token, Unraid licence key) are in the repos and tarballs **in clear, by choice** (files are mode 600); never put them in git.

### 12.5 The laptop
Per the owner: `~/bin/restic/restic_backup.sh` backs the laptop up to the NAS (`Backup/Framework`) and also pulls from the NAS share `Backup/{unraid_appdata,unraid_config,proxmox_config}`. The restic repos keep every retained snapshot (7 daily / 4 weekly / 6 monthly), so a pull of a repo folder brings the history too.

**Names do not match yet.** Butlah writes to `Backup/Butlah/proxmox-config` and `Backup/Butlah/unraid-config` (no `unraid_appdata`: appdata is empty). The laptop script expects `Backup/proxmox_config`, `Backup/unraid_config`, `Backup/unraid_appdata`. One side has to change (see the open question at the end of the build log / ask the owner). `/root/backup/laptop-pull.sh` and `laptop-gate.sh` (pull `/srv/backup` straight from butlah) exist but are optional now that the NAS share already has both repos; they are not installed.

### 12.6 Unraid access (important)
- Butlah reaches Unraid with **`/root/.ssh/id_ed25519_backup`** (no passphrase, so timers can use it). `/root/.ssh/id_ed25519` has a passphrase and only works in a shell with an ssh-agent (that is why the AI session could not use it).
- On Unraid that key is **read-only by design**: in `/boot/config/ssh/root/authorized_keys` it is forced to `from="192.168.1.200",restrict,command="bash /boot/config/ssh/backup-gate.sh"`. The gate allows only `rsync --server --sender` under `/boot/config` and `/mnt/user/appdata`, plus the words `unraid-plugins` and `unraid-vm-xml`. Unraid's `/root` is RAM, so keys also have to be on the flash copy. To pull more (e.g. `/boot/syslinux`), edit the gate on Unraid.
- Our Unraid copy is a small config copy (about 0.4 MB), not a flash image: it skips plugin packages and OS images. Unraid's own flash backup (Connect / Main > Flash) is separate and still the full copy.

### 12.7 Gotchas
- vzdump starts hooks with a minimal `PATH`; `lib/common.sh` sets its own. New hook code must too.
- A restored VM keeps the original MAC, IP and Tailscale node key: remove its NIC before first boot.
- `restic check` on a read-only NFS mount hangs (it needs a lock): mount read-write or use `--no-lock`.
- The `Backup` mount is taken under a lock (`/run/backup-share.lock`) so one job's unmount cannot pull it from under another.
- No PBS datastore or restic repo on `/mnt/user` paths over NFS (shfs stale handles, section 7.6); the PBS vdisk points straight at `/mnt/disk3/...`.
- Disks are created with `discard = "on"` and `ssd = true` in Terraform (2026-10-15). Without discard the thin pool never frees deleted blocks and PBS backs up the stale ones (347 GiB allocated vs about 165 GiB really used; 186 GiB after `fstrim`). **`terraform.tfvars` must mirror the live sizes and RAM**: change a disk or memory in Proxmox and update it in the same step, or the next `plan` wants to shrink it back. Compute (208, GPU) must keep `cpu_type = "host"`.

### 12.8 Known gaps
- **PBS itself is not backed up** (OS disk `/mnt/user/domains/...`, users, tokens). Rebuild steps are in the runbook (`--reuse-datastore`).
- **One copy of VM disks, on one array disk.** Parity protects against a disk dying, not against deletion or corruption. No offsite copy yet; a PBS sync job to a second target is the easy next step.
- **The `Backup` NFS export is LAN-wide and the repos in it hold secrets in clear.** Restrict it to butlah and the laptop.
- The PBS prune job (7/4/6) is set by the owner on the PBS VM and has not been checked from butlah; `backup-check.sh` alerts if a guest piles up over 30 snapshots.

Restore procedures (one VM, one file, a database dump, rebuilding butlah, Unraid or both): **`/root/backup/RESTORE-RUNBOOK.md`**.
