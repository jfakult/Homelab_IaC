#!/usr/bin/env python3
"""compare_sqlite_pg.py - check that a SQLite database and a PostgreSQL database hold the same DATA.

  compare_sqlite_pg.py SQLITE_FILE "postgresql://user:pw@host:port/db" [--skip TABLE ...]

For every table present in both (minus --skip) the rows are normalised by the PostgreSQL column type
(0/1 vs boolean, JSON text vs parsed JSON, datetime text vs timestamp, float rounding) and compared
as multisets, so row order does not matter. Prints one line per non-empty table and shows the first
differences. Exit status 0 only if every table is identical. Use it after sqlite_to_pg.py.
"""
import argparse
import collections
import datetime
import json
import re
import sqlite3
import sys
import decimal

import psycopg2

DT = re.compile(r'^\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d')


def canon(v, t, from_sqlite):
    """Canonical comparable form of one value. SQLite hands back what it stored (text/ints); psycopg2 hands
    back native types, so both sides are reduced to the same strings. JSON null and SQL NULL are equivalent."""
    if t in ('json', 'jsonb'):
        if from_sqlite and isinstance(v, str):
            try:
                v = json.loads(v)
            except ValueError:
                pass
        return None if v is None else json.dumps(v, sort_keys=True)
    if v is None:
        return None
    if t == 'boolean':
        return str(int(v) if not isinstance(v, str) else int(v.strip().lower() in ('1', 't', 'true')))
    if t.startswith('timestamp') or t == 'date':
        s = v.isoformat(sep=' ') if hasattr(v, 'isoformat') else str(v)
        if re.match(r'^\d{4}-\d\d-\d\d$', s):      # SQLite keeps a bare date; Postgres a midnight timestamp
            s += ' 00:00:00'
        return s[:19] if DT.match(s) else s
    if isinstance(v, (float, decimal.Decimal)):
        return repr(round(float(v), 6))
    if isinstance(v, memoryview):
        return bytes(v).hex()
    if isinstance(v, bytes):
        return v.hex()
    if isinstance(v, str) and DT.match(v):
        return v[:19]
    return str(v)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('sqlite_file'); ap.add_argument('pg_url'); ap.add_argument('--skip', nargs='*', default=[])
    a = ap.parse_args()
    s = sqlite3.connect('file:%s?mode=ro' % a.sqlite_file, uri=True)
    s.text_factory = lambda b: b.decode('utf-8', 'replace')
    cur = psycopg2.connect(a.pg_url).cursor()
    st = {r[0] for r in s.execute("select name from sqlite_master where type='table' and name not like 'sqlite_%'")}
    cur.execute("select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE'")
    both = sorted((st & {r[0] for r in cur.fetchall()}) - set(a.skip))
    bad = 0
    for t in both:
        cur.execute("select column_name, data_type from information_schema.columns where table_schema='public' and table_name=%s", (t,))
        pt = dict(cur.fetchall())
        cols = [r[1] for r in s.execute('pragma table_info("%s")' % t) if r[1] in pt]
        if not cols:
            continue
        q = ', '.join('"%s"' % c for c in cols)
        A = collections.Counter(tuple(canon(v, pt[c], True) for c, v in zip(cols, r))
                                for r in s.execute('select %s from "%s"' % (q, t)))
        cur.execute('select %s from "%s"' % (q, t))
        B = collections.Counter(tuple(canon(v, pt[c], False) for c, v in zip(cols, r)) for r in cur.fetchall())
        n = sum(A.values())
        if not n and not sum(B.values()):
            continue
        ok = A == B
        bad += not ok
        print('%-38s %6d rows  %s' % (t, n, 'identical' if ok else 'DIFFERENT (sqlite %d, postgres %d)' % (n, sum(B.values()))))
        if not ok:
            for row in list((A - B).elements())[:2]:
                print('    only in SQLite  :', [str(x)[:50] for x in row][:8])
            for row in list((B - A).elements())[:2]:
                print('    only in Postgres:', [str(x)[:50] for x in row][:8])
    print('\nALL IDENTICAL' if not bad else '\n%d table(s) differ' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
