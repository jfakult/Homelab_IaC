# Moving an app's database from SQLite to pg-main

Policy: every database that can live on the db VM (203) does. Apps that only
speak SQLite (Pi-hole, Jellyfin, the journal's vector store) stay local and are
covered by `/root/backup/vm-dumps.json`. Each migrated app gets its own role +
database in `pg_databases` (`inventory/group_vars/infra.yml`); its dump is then
part of the db VM's `pg_dumpall` and its `sqlite` entry leaves `vm-dumps.json`.

Rules for every migration: one app at a time; keep the old SQLite file until the
app has run cleanly for a day; the SQLite file is never modified by the switch,
so rolling back is flipping the setting back and recreating the container.

## Pocket-ID (204) - SQLite -> `pocketid` on pg-main

Pocket-ID (v2.14) exports all its data to a ZIP and imports it again, so the
move is: export, point it at an empty Postgres database, import.

SSO is unavailable for a few minutes (existing sessions in other apps keep
working; new logins fail). Pick a quiet moment. Until the import finishes the
fresh instance shows the first-run setup page, so do steps 4-5 back to back.

1. Pick a password (letters and digits only) and add
   `vault_pocket_id_postgres_password` with
   `ansible-vault edit inventory/group_vars/all/vault.yml`.
2. Create the role and database (no effect on Pocket-ID yet):
   `ansible-playbook -i inventory/hosts.ini site.yml --tags db --limit db -J`
3. Export, from butlah (read-only against the live instance):
   `qm guest exec 204 -- docker exec pocket-id /app/pocket-id export -p /app/data/pre-postgres-export.zip`
   then check it exists and is not empty:
   `qm guest exec 204 -- ls -la /opt/pocket-id/data/pre-postgres-export.zip`
4. Set `pocket_id_use_postgres: true` in `infra.yml` and deploy:
   `ansible-playbook -i inventory/hosts.ini site.yml --limit sso -J`
   Pocket-ID recreates against the empty database. It will show the first-run page
   and, because it restarts, it holds a cluster lock in the database.
5. Import **with the service stopped and nothing else touching the database**.
   Do NOT run the import inside the running container and then restart it: the
   restart policy brings the instance straight back, it races the import for the
   lock, the import is killed (exit 137) before loading anything, and Pocket-ID
   then crash-loops with "the cluster is locked for exclusive access" (this
   happened on 2026-10-18; no data was lost, the database was empty).
   ```
   qm guest exec 204 -- bash -c "cd /opt/pocket-id && docker compose stop pocket-id"
   # if an earlier attempt left a stale lock, recreate the (empty) database:
   #   psql as the admin role on 203: DROP DATABASE pocketid; CREATE DATABASE pocketid OWNER pocketid;
   qm guest exec 204 --timeout 0 -- bash -c "cd /opt/pocket-id && docker compose run --rm --no-deps -T pocket-id /app/pocket-id import -p /app/data/pre-postgres-export.zip -y > /tmp/pid-import.log 2>&1; echo exit=\$? >> /tmp/pid-import.log"
   qm guest exec 204 -- tail -5 /tmp/pid-import.log     # wait for "Import completed successfully." and exit=0
   qm guest exec 204 -- bash -c "cd /opt/pocket-id && docker compose up -d pocket-id"
   ```
   Before starting the service, compare row counts in the `pocketid` database with the
   export (users, user_groups, oidc_clients, webauthn_credentials, audit_logs, ...).
6. Verify: log in at https://sso.fakult.net, check users, groups, OIDC clients
   (blinko-journal, Open WebUI, Jellyfin, and Immich once added) and passkeys,
   then log in to Open WebUI through SSO.
7. After a clean day: remove the `204` entry from `/root/backup/vm-dumps.json`
   (the db VM dump now covers it), and delete
   `/opt/pocket-id/data/pocket-id.db*` and the export ZIP (both hold secrets).

Rollback (any time before step 7): set `pocket_id_use_postgres: false`, redeploy
sso. The SQLite file in `/opt/pocket-id/data` is untouched and Pocket-ID resumes
with the data it had at step 3 (changes made after the switch are lost).
