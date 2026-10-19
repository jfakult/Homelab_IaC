# Immich (photos.fakult.net)

Family photo library (replaces Google Photos). Three VMs, one version
(`immich_version` in `inventory/group_vars/all/main.yml`):

| Piece | VM | What | Role / tag |
|---|---|---|---|
| `immich-server` + `immich-valkey` | webapps (205) | web, API, job workers, :2283; metrics :8081/:8082 | `roles/webapps/tasks/immich.yml`, tag `immich` |
| `immich-machine-learning` (CUDA) | compute (208) | smart search (CLIP), faces, OCR, :3003, on the GPU | `roles/compute/tasks/immich_ml.yml`, tags `immich`, `gpu` |
| `pg-immich` (VectorChord Postgres) | db (203) | Immich's database, :5433, data in `/opt/postgres-immich/data` on the VM disk | `roles/db/tasks/immich_postgres.yml`, tag `immich` |

The library (originals, thumbnails, encoded video, Immich's own DB dumps) is on
its own NAS share, `Immich`, mounted on webapps at `/srv/photos` and bound
into the container at `/mnt/photos` (the share *root*, see the kiwix compose for
why). `IMMICH_MEDIA_LOCATION=/mnt/photos`. A dedicated share keeps its Unraid
settings (cache/mover, disks, snapshots, the future cloud backup) separate from
the other data. The NAS
resilience tooling covers it: boot wait, watchdog, and `autoheal` restarts the
server when its healthcheck cannot read the library. Immich also refuses to
start when its `.immich` marker files are missing, so an unmounted share never
gets a second, empty library.

Settings are in `/opt/immich/immich-config.json` (rendered from
`roles/webapps/tasks/templates/immich-config.json.j2`) and read through
`IMMICH_CONFIG_FILE`: ML URL, OAuth, storage template, trash, external domain.
Those settings are read-only in the admin UI (Immich locks the whole page when a
config file is used; there is no layering). Everything not in the file (jobs,
ffmpeg, map, ...) stays at Immich's defaults; add keys to the template to manage
them. Also set there: user delete delay 30 days, 1 TiB default quota for SSO-created
users (`immich_default_quota_gib`; locally created users get a quota per user in
Administration -> Users), mail through the monitoring VM's postfix relay
(`192.168.1.211:25`, sender = `smtp_relay_username`), Immich's own database dump
and the new-version check switched off (the db VM backup covers the database,
monitoring covers container age). To find good values, set `immich_config_managed:
false`, tune in the UI, copy the JSON from the settings page into the template,
and switch back. Set `immich_config_managed: false` in `group_vars/apps.yml` to
manage the settings in the UI instead.

## First deploy (owner steps, in order)

0. **NAS share**: Unraid share `Immich` (`/mnt/user/Immich`), NFS export restricted to the webapps VM only,
   e.g. rule `192.168.1.205(sec=sys,rw,no_root_squash)` (NFSv4, root must not be squashed: the container
   writes as root). Storage: cache pool as primary, Array as secondary, mover cache -> array, so uploads
   land on fast cache and end up on the Array. Verify in the Unraid UI: Shares -> Immich ->
   Primary storage = cache pool, Secondary storage = Array, Mover action = Cache to Array; Settings ->
   Scheduler -> Mover Settings shows the mover schedule. The webapps play mounts it at `/srv/photos`.
1. **Vault** (`ansible-vault edit inventory/group_vars/all/vault.yml`), three new keys:
   - `vault_immich_postgres_password`: letters and digits only (`openssl rand -hex 24`).
   - `vault_immich_oidc_client_id` / `vault_immich_oidc_client_secret`: fill after step 5, a placeholder is fine until then (OAuth login just won't work yet).
2. **DNS**: public A record `photos.fakult.net` (same IP as `sso`/`chat`), and a local
   Pi-hole record `photos.fakult.net` -> 192.168.1.201 (bastion) like the other subdomains.
3. **Database**: `ansible-playbook -i inventory/hosts.ini site.yml --limit db --tags immich -J`
   (pulls the image, starts `pg-immich`, locks `pg_hba.conf` to webapps + Tailscale, opens UFW :5433).
4. **ML on compute** (the first start downloads the models from Hugging Face): the compute play opens
   the WAN toggle for its own duration and closes it again at the end (`site.yml`), so just run
   `ansible-playbook -i inventory/hosts.ini site.yml --limit compute --tags immich -J`.
   The play waits until `/ping` answers, which is after the preload finished. Check with
   `docker logs immich-machine-learning` (expect `CUDAExecutionProvider`).
5. **Pocket-ID client** (by hand at https://sso.fakult.net, no API): name `Immich`, callback URLs
   - `https://photos.fakult.net/auth/login`
   - `https://photos.fakult.net/user-settings`
   - `https://photos.fakult.net/api/oauth/mobile-redirect` (the mobile app flow, because `mobileOverrideEnabled` is on)
   - `app.immich:///oauth-callback` (only needed if the mobile redirect above is turned off)

   Put the client id/secret in the vault (step 1). Optionally restrict it to a Pocket-ID user group.
6. **Server**: `ansible-playbook -i inventory/hosts.ini site.yml --limit webapps --tags immich -J`.
7. **Public access**: `ansible-playbook -i inventory/hosts.ini site.yml --tags nginx,certbot --limit bastion -J`
   (needs the public DNS record from step 2 for the certificate).
8. **First admin**: open https://photos.fakult.net, the first account created through the
   "Getting Started" form is the admin. That is the local break-glass login (password login stays on).
   Then log in with Pocket-ID once to check SSO. Family members are created on first SSO login
   (`autoRegister`); set an optional **storage label** per user (Administration -> Users) so each
   person gets their own folder (`{label}/{{y}}/...`); without one, files go under the user's id.
9. **Backups**: in `/root/backup/vm-dumps.json` remove `"enabled": false` from the `pg-immich`
   entry of VM 203 once the container exists (then `lib/gen_vm_dump.py --list` shows it enabled).

## Checks

```
curl -s https://photos.fakult.net/api/server/ping            # {"res":"pong"}
vmx webapps 'docker ps --filter name=immich --format "{{.Names}}: {{.Status}}"'
vmx db 'docker exec pg-immich psql -U immich -d immich -c "select extname, extversion from pg_extension"'   # vchord, vector
vmx compute 'docker logs immich-machine-learning 2>&1 | grep -i provider'
```
Smart search and face jobs: Administration -> Jobs; the GPU shows the load in
`nvidia-smi` on compute. Models unload after 5 minutes idle so the GPU is shared
with Ollama and Whisper.

## Storage template

`{{y}}/{{y}}-{{MM}}/{{filename}}` (year / year-month / original filename), enabled before
any import so nothing needs moving. Changing the template later needs the
"Storage template migration" job and moves files on the NAS. The original filename can collide
only inside the same month folder; Immich then appends a counter.

## Monitoring

Prometheus scrapes the API and worker metrics (`:8081`, `:8082`; v3 metric names use dots) and a
blackbox probe hits `/api/server/ping`. No dashboards or alerts yet (monitoring audit TODO in context.md).
Docker logs are capped at 10 MB x 3.

## Google Takeout import

Use `immich-go` (run on any machine that can reach the server; an API key from the user's account
settings). Do a dry run on one small album first, then the rest. It keeps albums and dates and merges the
Takeout JSON sidecars; photo "descriptions" come across, tags are added in the UI afterwards.
Take a Proxmox backup of webapps and the db VM before the big import.

## Operating notes

- **Admins can see everything.** The admin account can browse all users' photos; there is no end-to-end
  encryption. Shared albums and partner sharing are per user.
- **Upgrades**: bump `immich_version` (server, ML, and `immich_pg_image` from that release's
  `docker-compose.yml`), read the release notes for breaking changes, take a dump of `pg-immich` first,
  then re-run the db, compute and webapps plays. Never upgrade the server alone: ML must match.
- **Backup**: the nightly `pg_dumpall` of `pg-immich` is in `/var/backups/vm-dumps` on the db VM (included
  in the VM backup). Immich's own scheduled DB dump is switched off. The photos themselves are on the NAS
  only until the offsite backup is enabled: `cloud-backup.json` has a `photos` repo for the Immich share
  (context.md 12.9). Decide there how the Immich database goes offsite too, because the files alone do
  not carry albums, faces or users; the simplest is to switch Immich's own DB dump back on, so it lands
  in the library that the `photos` repo backs up.
- **Mobile app**: server URL `https://photos.fakult.net`; "Free up space" removes local copies of backed-up
  photos.
- **Rollback**: stop the stack (`docker compose down` in `/opt/immich`); data is untouched. To start over,
  also drop the `pg-immich` data directory and the NAS `immich` folder (owner decision).
