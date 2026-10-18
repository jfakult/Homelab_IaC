#!/usr/bin/env python3
"""sqlite_to_pg.py - copy the DATA of a SQLite database into an existing PostgreSQL schema.

For apps (Grafana, Open WebUI, speedtest-tracker, ...) that can run on either engine and create their
own tables on first start: start the app once against the empty Postgres database so it creates the
schema, stop it, run this, start it again. See ansible/docs/postgres-migrations.md.

  sqlite_to_pg.py SQLITE_FILE "postgresql://user:pw@host:port/db" [--skip TABLE ...] [--dry-run]

- Opens the SQLite file read-only; every table present in both databases is copied (SQLite internals,
  tables listed in --skip and tables that exist only on one side are left alone and reported).
- Values are converted by the PostgreSQL column type (0/1 -> boolean, TEXT -> json/jsonb, ...).
- Target tables are emptied first, loaded in one transaction with foreign-key triggers disabled
  (needs a superuser connection), sequences are reset, and source/target row counts are compared.
- Exit status 0 only if every copied table has the same row count on both sides.
"""
import argparse
import json
import sqlite3
import sys

import psycopg2
from psycopg2.extras import execute_values


def convert(value, pg_type):
    if value is None:
        return None
    if pg_type == 'boolean':
        if isinstance(value, (bytes, str)):
            return str(value).strip().lower() in ('1', 't', 'true', 'yes')
        return bool(value)
    if pg_type in ('json', 'jsonb'):
        return value if isinstance(value, str) else json.dumps(value)
    if pg_type == 'bytea':
        return psycopg2.Binary(value if isinstance(value, bytes) else str(value).encode())
    if isinstance(value, bytes) and pg_type in ('text', 'character varying', 'character'):
        return value.decode('utf-8', 'replace')
    return value


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('sqlite_file')
    ap.add_argument('pg_url')
    ap.add_argument('--skip', nargs='*', default=[])
    ap.add_argument('--dry-run', action='store_true', help='report what would be copied, change nothing')
    a = ap.parse_args()

    src = sqlite3.connect('file:%s?mode=ro' % a.sqlite_file, uri=True)
    src.text_factory = lambda b: b.decode('utf-8', 'replace')
    dst = psycopg2.connect(a.pg_url)
    cur = dst.cursor()

    s_tables = {r[0] for r in src.execute("select name from sqlite_master where type='table' and name not like 'sqlite_%'")}
    cur.execute("select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE'")
    p_tables = {r[0] for r in cur.fetchall()}
    both = sorted((s_tables & p_tables) - set(a.skip))
    print('only in SQLite (not copied):', sorted(s_tables - p_tables - set(a.skip)) or '-')
    print('only in Postgres (left empty):', sorted(p_tables - s_tables) or '-')
    print('skipped:', sorted(set(a.skip) & s_tables) or '-')

    plan = []
    for t in both:
        cur.execute("select column_name, data_type from information_schema.columns where table_schema='public' and table_name=%s order by ordinal_position", (t,))
        pcols = dict(cur.fetchall())
        scols = [r[1] for r in src.execute('pragma table_info("%s")' % t)]
        cols = [c for c in scols if c in pcols]
        lost = [c for c in scols if c not in pcols]
        if lost:
            print('WARNING %s: SQLite columns with no Postgres column (data NOT copied): %s' % (t, lost))
        plan.append((t, cols, pcols))
    if a.dry_run:
        for t, cols, _ in plan:
            print('%-40s %6d rows, %d columns' % (t, src.execute('select count(*) from "%s"' % t).fetchone()[0], len(cols)))
        return 0

    cur.execute("set session_replication_role = replica")      # skip FK triggers during the load (superuser)
    if plan:
        # one statement: Postgres refuses to truncate a table that other tables reference unless
        # those are truncated in the same command
        cur.execute('truncate table %s' % ', '.join('"%s"' % t for t, _, _ in plan))
    bad = 0
    print('\n%-40s %8s %8s' % ('table', 'sqlite', 'postgres'))
    for t, cols, pcols in plan:
        qcols = ', '.join('"%s"' % c for c in cols)
        rows = [tuple(convert(v, pcols[c]) for v, c in zip(r, cols)) for r in src.execute('select %s from "%s"' % (qcols, t))]
        if rows:
            execute_values(cur, 'insert into "%s" (%s) values %%s' % (t, qcols), rows, page_size=500)
        cur.execute('select count(*) from "%s"' % t)
        n = cur.fetchone()[0]
        flag = '' if n == len(rows) == src.execute('select count(*) from "%s"' % t).fetchone()[0] else '   <-- MISMATCH'
        bad += bool(flag)
        print('%-40s %8d %8d%s' % (t, len(rows), n, flag))
    # reset serial/identity sequences to follow the copied ids
    cur.execute("""select c.table_name, c.column_name from information_schema.columns c
                   where c.table_schema='public' and pg_get_serial_sequence('"'||c.table_name||'"', c.column_name) is not null""")
    for t, c in cur.fetchall():
        cur.execute("select setval(pg_get_serial_sequence(%s, %s), coalesce((select max(\"" + c + "\") from \"" + t + "\"), 1), "
                    "(select max(\"" + c + "\") from \"" + t + "\") is not null)", ('"%s"' % t, c))
    cur.execute("set session_replication_role = default")
    if bad:
        dst.rollback()
        print('\nROLLED BACK: %d table(s) did not match' % bad)
        return 1
    dst.commit()
    print('\nCommitted. All copied tables match.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
