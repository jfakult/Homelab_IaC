# _webapps - NAS backup copy of the webapps VM's apps

**This folder is a backup mirror. Nothing runs from here, and edits made here
are overwritten.** The live apps are on the webapps VM (192.168.1.205) at
`/srv/webapps/`. Make changes there.

This file is deployed by Ansible (`roles/webapps`, `Homelab_IaC` repo); edit it
there, not here.

## Where things are

| Path | What it is |
|---|---|
| webapps VM `/srv/webapps/<app>/` | **Live copy, local disk.** Every systemd unit runs from here. Not in git or Ansible; apps are added by hand. |
| NAS `/mnt/user/Server_WebappsCache/_webapps/` (mounted on webapps + bastion as `/srv/www/_webapps/`) | **This folder.** One-way mirror of the live copy, refreshed every 3h. |
| bastion VM `/srv/webapps/` | Stale leftover from the migration (2023-era files). Nothing uses it. |

`Server_WebappsCache` (`/srv/www`) is also bastion nginx's static web root
(`/usr/share/nginx/html`). nginx blocks `/_webapps` explicitly (returns 404),
so this folder is not served to the web.

## How the apps run (webapps VM)

- Each `/srv/webapps/<app>/` has a `start.sh` and a `stop.sh`. Folders whose
  names start with `_` (like `_template` and `_market`) are skipped.
- `/srv/generate_web_daemons.sh` (also called by `webappctl.sh scan`) writes one
  unit per app, `/etc/systemd/system/webapp-<app>.service`, with
  `WorkingDirectory=/srv/webapps/<app>`, `ExecStart=./start.sh`,
  `ExecStop=./stop.sh`, `Restart=always` and `User=root`. It moves the previous
  units into `/srv/webapps/archive/` first.
- `/srv/webappctl.sh start|stop|restart|status [app]` wraps `systemctl` for
  every `webapp-*` unit (or one app). Ansible runs `scan` and then `start` on
  every webapps play.
- Bastion nginx proxies the public paths to ports on the webapps VM (snippet
  `nodeJS_servers.conf`). For example, `/resume` goes to `:3010`
  (`resume/index_resume.js`) and `/l` goes to `:8100` (`link_shortener`).

## The sync

- `webapps-nas-sync.timer` runs every 3 hours (plus a random delay of up to
  10 min, and catches up after downtime). It triggers
  `webapps-nas-sync.service`, which runs `/srv/sync_webapps_to_nas.sh`.
- The script runs `rsync -a --chown=1000:100 /srv/webapps/ /srv/www/_webapps/`:
  - **Local wins.** Any file whose size or mtime differs is re-copied from
    the VM, so edits made here are replaced on the next run.
  - **No `--delete`.** Files deleted on the VM, or files that only exist here
    (this `context.md`, and old `.git`, `.quasar` and similar files at the top
    level), are left in place.
  - Ownership is set to `ubuntu:users` (1000:100), to match the rest of the
    share.
  - It skips the run (and fails) if `/srv/www` is not really the NAS mount.
  - It runs at nice 19 with idle I/O priority. A normal run only stats about
    5k files and copies whatever changed.
- Check it with:
  `systemctl list-timers webapps-nas-sync.timer` and
  `journalctl -u webapps-nas-sync -n 20`.
  Run it now with `systemctl start webapps-nas-sync`.

## Restoring an app from here

```
rsync -a --chown=ubuntu:ubuntu /srv/www/_webapps/<app>/ /srv/webapps/<app>/
/srv/webappctl.sh scan && /srv/webappctl.sh start <app>
```

`node_modules` and `.venv` folders are mirrored too, but if an app misbehaves
after a restore, reinstall its dependencies (`npm ci`, or recreate the venv).

## Known issues (as of 2026-09-23)

- 11 of the 19 `webapp-*` units are in restart loops. For example, `stocks`
  fails with `su: user butlah does not exist`, left over from the old
  bare-metal host.
- `webapp-archive.service` is bogus: the scan treats `/srv/webapps/archive`
  (its own unit backup folder) as an app.
