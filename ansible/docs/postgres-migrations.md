# Moving an app's database from SQLite to pg-main

Policy: every database that can live on the db VM (203) does. Apps that only
speak SQLite (Pi-hole, Jellyfin, the journal's vector store) stay local and are
covered by `/root/backup/vm-dumps.json`. Each migrated app gets its own role +
database in `pg_databases` (`inventory/group_vars/infra.yml`); its dump is then
part of the db VM's `pg_dumpall` and its `sqlite` entry leaves `vm-dumps.json`.

Rules for every migration: keep the old SQLite file, its nightly copy
(`/var/backups/vm-dumps/*.bak`) and any export for as long as the owner says
(never delete them as part of "cleanup"); the SQLite file is never modified by the
switch, so rolling back is flipping the setting back and recreating the container.
Rehearse first on a scratch Postgres (see below); the real move then repeats the
same commands against pg-main.

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


## Grafana, speedtest-tracker, Open WebUI (monitoring VM 211 and compute 208)

None of these has an official SQLite-to-Postgres tool. Open WebUI's docs say it does
not migrate data between databases; Grafana's forum recommends letting Grafana create
the Postgres schema and then loading data only (full pgloader loads fail on type
differences). That is what `scripts/sqlite_to_pg.py` does, with a value-level check in
`scripts/compare_sqlite_pg.py`:

1. The app starts once against an EMPTY Postgres database and creates its own schema.
2. The app is stopped (so nothing writes to either side).
3. `sqlite_to_pg.py <snapshot.sqlite> <postgres url> --skip <bookkeeping tables>` empties
   the target tables in one statement, loads every table that exists on both sides with
   values converted by the Postgres column type (0/1 -> boolean, text -> json), resets
   the sequences, and refuses to commit unless every row count matches.
4. `compare_sqlite_pg.py` compares the actual values, not just counts.
5. The app starts on the copied data.

Tables left to the new database (bookkeeping the app wrote itself on first start):
speedtest-tracker `migrations`; Grafana `migration_log`, `resource_migration_log`,
`secret_migration_log`, `server_lock`; Open WebUI `alembic_version`.
The tools need a superuser connection (they disable foreign-key triggers while loading)
and `psycopg2`: run them on the db VM, which has it, with the SQLite snapshot copied there.

Rehearsed 2026-10-18 on a throwaway Postgres (same app versions as production:
speedtest-tracker v1.15.0, Grafana 12.2.1, Open WebUI 0.11.3). All three produced
identical data. Known harmless differences: rows the rehearsal app wrote itself on
start (a session, `login_attempt`, a refreshed alert-config timestamp).

Done 2026-10-18: Pocket-ID, speedtest-tracker, Grafana and Open WebUI are on pg-main; the copies were
verified value-by-value and the pre-migration SQLite snapshots are kept in
`/root/backup/pre-postgres-migrations/` (plus the originals and nightly `.bak` files on the VMs).

Steps for the real move (flags `speedtest_use_postgres`, `grafana_use_postgres` in
`infra.yml`, `open_webui_use_postgres` in `apps.yml`):

1. Vault keys (letters and digits only): `vault_speedtest_postgres_password`,
   `vault_grafana_postgres_password`, `vault_open_webui_postgres_password` and
   `vault_grafana_admin_password` (the Grafana admin password as set in the UI).
2. `ansible-playbook -i inventory/hosts.ini site.yml --tags db --limit db -J`
   creates the three roles/databases.
3. Set the flags to `true`. Deploy and immediately stop the apps so they hold the
   empty database only briefly:
   `ansible-playbook -i inventory/hosts.ini site.yml --limit monitoring -J && qm guest exec 211 -- bash -c "cd /opt/monitoring && docker compose stop grafana speedtest-tracker"`
   `ansible-playbook -i inventory/hosts.ini site.yml --tags chat --limit compute -J && qm guest exec 208 -- bash -c "cd /opt/open-webui && docker compose stop open-webui"`
   Each app has now created its schema in Postgres and is stopped.
4. Copy, verify, start (run per app; snapshot with `vzdump-hook.sh --run <vmid>` first).
5. After a clean day, remove the migrated `sqlite` entries from `/root/backup/vm-dumps.json`
   (211: both; 208: only `webui.db`, the chroma index stays local) and tick the TODO in
   `context.md`. The SQLite originals and `.bak` copies stay until the owner says otherwise.

