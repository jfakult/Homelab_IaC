# Homelab IaC - context for AI assistants (and humans)

Read this first. It explains how the Proxmox box, the VMs, the network/DNS/SSO
plumbing, the Ansible repo and the git workflow fit together, plus the
traps that have already bitten us. Written 2026-09-21; things marked
**(verified live)** were checked against the running system that day, the rest
comes from the repo's config. **The repo and the live system win over this
file** - if they disagree, trust them and fix this doc.

`README.md` is the original design blueprint and is partly stale (it says
Authelia; SSO is Pocket-ID now). This file supersedes it for "how things work today".
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

- One physical Proxmox host, **butlah** (192.168.1.200, `butlah.fakult.net`), 11 Ubuntu 24.04 VMs.
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
(webapps, media, storage, compute), `lab` (containerlab, misc).

| VMID/host | IP | Runs (Compose project dir) | Notes |
|---|---|---|---|
| butlah (Proxmox) | .200 | no exporters (**verified live**: nothing on 9100/9113/8080) | **Not in ansible inventory.** `/etc/resolv.conf` lists 192.168.1.202 first (hand-managed). |
| 201 bastion | .201 | `rp-nginx` (/opt/gateway), certbot, cadvisor, exporters | Only public-facing VM. TLS termination + reverse proxy. |
| 202 dns | .202 | `dns-pihole-1`, `dns-unbound-1` (/opt/dns), NordVPN client | Pi-hole web at `http://192.168.1.202/admin`. |
| 203 db | .203 | `pg-main` postgres:16 (/opt/postgres) | Legacy Authentik DB + `blinko` DB for the journal. Only `provision_blinko.yml` is wired into `site.yml`. Superuser role is **`authentik`** (there is no `postgres` role). |
| 204 sso | .204 | `pocket-id` (/opt/pocket-id), port 1411 | OIDC provider for everything. |
| 205 webapps | .205 | `blinko-website` (/opt/journal, :1111), `kiwix` (/opt/kiwix), `geo-proxy` (/opt/geo-proxy, :8091) | The AI journal. Image `ghcr.io/jfakult/blinko-journal:latest` built by GitHub Actions in the *separate* `jfakult/blinko-journal` repo. NAS mounts `/srv/www`, `/srv/nas`. `geo-proxy` is a reverse-geocoding proxy, LAN/Tailscale-only (not on a bastion subdomain). Also runs the legacy non-Docker `webapp-*` systemd apps (resume etc., section 7.5). |
| 206 media | .206 | `jellyfin` (:8096) + exporters (/opt/jellyfin) | Media on NAS via NFS. Jellyfin SSO plugin uses Pocket-ID. |
| 207 storage | .207 | nothing (no Docker; role empty) | Placeholder. |
| 208 compute | .208 | `ollama` (:11434), `whisper` (:8000), `open-webui` (:3000), `searxng` (:8888) | RTX 4060 Ti 16GB passed through (hostpci0), 32GB RAM, 256GB disk. See section 7. |
| 209 containerlab | .209 | nothing | Placeholder. |
| 210 misc | .210 | nothing | Scratchpad. |
| 211 monitoring | .211 | prometheus :9090, grafana :3000, loki :3100, alertmanager :9093, blackbox :9115, smokeping, speedtest-tracker, `postfix-relay` (/opt/monitoring) | See section 7. |
| NAS | .199 | Unraid (NFS 4.2 shares under `/mnt/user/...`) | Separate physical box, not managed here. |

## 4. Network, DNS, TLS, SSO

### 4.1 DNS (most important - it has broken things several times)
```
VMs / butlah  ->  Pi-hole (192.168.1.202, dns VM, docker *host* network)
                     -> Unbound (127.0.0.1:5335, recursive)  -> root servers
```
- **Every VM's `/etc/resolv.conf`** is pushed by the `base` role from
  `roles/misc/templates/resolv.conf`: `192.168.1.202`, then `9.9.9.9`, `1.1.1.1`, `8.8.8.8`.
  Static records come from `roles/dns/templates/static-hosts.conf.j2`:
  `address=/fakult.net/192.168.1.201` (bare domain + any unlisted subdomain -> bastion),
  each VM as `<name>.fakult.net`, and one line per entry in the `subdomains` list.
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
  -> sso -> bastion -> dns -> media -> db (**tag `journal`**, only `provision_blinko.yml`)
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
  both compute and webapps): `ollama_chat_model_base` -> the served chat model is
  `<base>-safe`, a local Modelfile build with a hard `num_predict` cap
  (`roles/compute/tasks/templates/chat-model-capped.Modelfile.j2`). Reason: an
  uncapped qwen3.5:9b generation ran 40k+ tokens for ~2 hours (Ollama's default
  `num_predict` is unbounded). Also `ollama_post_processing_model`,
  `ollama_embedding_model`, `ollama_vision_model`. Ollama env: `OLLAMA_CONTEXT_LENGTH`,
  `OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_KEEP_ALIVE` in the ollama compose template.
- VRAM is the real constraint (16GB shared with Whisper): e.g. gemma4:e4b is 9.6GB on
  disk despite its "small" name. Raising `MAX_LOADED_MODELS` doesn't help if VRAM
  can't hold the models; Ollama will evict.
- **GPU self-healing** (all in the compute role): GPU access silently breaks (CPU
  fallback, no error) when dockerd *or containerd* restarts, when the NVIDIA CDI
  spec `/etc/cdi/nvidia.yaml` is missing/stale, or when the driver/kernel module
  versions mismatch. Guards: `gpu-containers-recreate.service` (regenerates the CDI
  spec and force-recreates ollama+whisper whenever docker/containerd restart),
  `gpu-health-check` timer (watches Ollama logs for CUDA init failure, self-heals,
  reboots after repeated failures), NVIDIA packages blacklisted from
  unattended-upgrades, `needrestart` told not to bounce containerd. Check GPU use with
  `curl localhost:11434/api/ps` (`size_vram` must be > 0) and `nvidia-smi`.
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
- Docker `json-file` logs are uncapped on the older monitoring containers; a crash
  loop filled a 10GB disk (disk was grown to 32GB). Use `logging.options`
  `max-size`/`max-file` in compose.
- Alertmanager treats missing SMTP config as **fatal** at startup (it crash-loops silently).

### 7.5 Legacy webapps (webapps VM, systemd, `webappctl`)
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
- Bastion's own `/srv/webapps` is a stale migration leftover and is unused.
  11 of the 19 units are in restart loops (for example, `stocks`:
  `su: user butlah does not exist`). `webapp-archive` is bogus: the scan picks
  up its own `archive/` folder.

### 7.6 Kiwix (webapps) and stale NAS handles
- `/opt/kiwix`, served at `fakult.net/wikipedia` (:3090). Zims are on the NAS
  under `/srv/nas/kiwix/zim` and `/srv/www/kiwix/zim`. The container binds the
  share **roots** read-only (`/mnt/nas`, `/mnt/www`) and rebuilds
  `/tmp/library.xml` on every start. The old `library.xml` in
  `/srv/www/kiwix/zim` is no longer used.
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

## 10. Known drift / open items (as of 2026-09-21)
- Pi-hole `listeningMode=ALL` set live in the container volume, not in Ansible.
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
