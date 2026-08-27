#!/usr/bin/env python3
"""Maintenance helper for Codex logs_2.sqlite persistent-log databases.

Codex writes diagnostic logs into a WAL-mode SQLite database. Older builds
placed it at ~/.codex/sqlite/logs_2.sqlite; newer builds moved it to
~/.codex/logs_2.sqlite and can leave the old file behind, bloated with
freelist pages. This tool finds both files, blocks new log inserts with a
trigger, and can vacuum reclaimed space.
"""

import os
import sqlite3
import sys
import time

USAGE = """Usage: codex_log_fix.py <command> [args]

Commands:
  status            show size, rows, trigger state for every logs_2.sqlite found
  check [seconds]   sample max log id for [seconds] (default 5) to detect live writes
  fix [db]          install the block_log_inserts trigger
  undo [db]         remove the trigger
  vacuum [db]       checkpoint WAL and VACUUM to reclaim space

Without a [db] argument, commands apply to every logs_2.sqlite found under
CODEX_HOME (default ~/.codex), including the legacy sqlite/ subdirectory.
"""


def human(n):
    n = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024.0 or unit == "TiB":
            return "%d B" % n if unit == "B" else "%.1f %s" % (n, unit)
        n /= 1024.0


def default_home():
    return os.path.join(os.path.expanduser("~"), ".codex")


def candidate_dbs():
    home = os.environ.get("CODEX_HOME") or default_home()
    paths = [
        os.path.join(home, "logs_2.sqlite"),
        os.path.join(default_home(), "sqlite", "logs_2.sqlite"),
        os.path.join(home, "sqlite", "logs_2.sqlite"),
    ]
    dbs, seen = [], set()
    for p in paths:
        p = os.path.normpath(p)
        if p in seen:
            continue
        seen.add(p)
        if os.path.exists(p):
            dbs.append(p)
    return dbs


def resolve_dbs(explicit):
    if explicit:
        if not os.path.exists(explicit):
            sys.exit("ERROR: database not found: %s" % explicit)
        return [explicit]
    dbs = candidate_dbs()
    if not dbs:
        sys.exit("ERROR: no logs_2.sqlite found under %s (set CODEX_HOME to override)"
                 % (os.environ.get("CODEX_HOME") or default_home()))
    return dbs


def uri_ro(p):
    return "file:" + p.replace("\\", "/") + "?mode=ro"


def snapshot(path):
    c = sqlite3.connect(uri_ro(path), uri=True, timeout=10)
    try:
        return c.execute("SELECT COUNT(*), COALESCE(MAX(id), 0) FROM logs").fetchone()
    finally:
        c.close()


def cmd_status(dbs):
    for p in dbs:
        print("Database:", p)
        for suffix in ("", "-wal", "-shm"):
            fp = p + suffix
            if os.path.exists(fp):
                st = os.stat(fp)
                mt = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(st.st_mtime))
                print("  %s: %s  (modified %s)" % (os.path.basename(fp), human(st.st_size), mt))
        try:
            c = sqlite3.connect(uri_ro(p), uri=True, timeout=10)
        except sqlite3.Error as e:
            print("  open failed: %s" % e)
            print()
            continue
        try:
            page = c.execute("PRAGMA page_size").fetchone()[0]
            pages = c.execute("PRAGMA page_count").fetchone()[0]
            free = c.execute("PRAGMA freelist_count").fetchone()[0]
            rows, max_id = c.execute("SELECT COUNT(*), COALESCE(MAX(id), 0) FROM logs").fetchone()
            trig = c.execute(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='block_log_inserts'"
            ).fetchone()[0]
            print("  rows=%d  max_id=%d  journal=wal" % (rows, max_id))
            print("  pages=%d  free=%d  reclaimable~%s" % (pages, free, human(free * page)))
            levels = c.execute("SELECT level, COUNT(*) FROM logs GROUP BY level ORDER BY 2 DESC").fetchall()
            if levels:
                print("  levels:", ", ".join("%s=%d" % (l, n) for l, n in levels))
            print("  fix trigger:", "installed" if trig else "not installed")
        finally:
            c.close()
        print()


def cmd_check(dbs, seconds):
    print("Keep Codex actively streaming during this %g-second check." % seconds)
    wal_before = {}
    for p in dbs:
        w = p + "-wal"
        wal_before[p] = os.stat(w).st_mtime_ns if os.path.exists(w) else 0
    a = {p: snapshot(p) for p in dbs}
    time.sleep(seconds)
    for p in dbs:
        w = p + "-wal"
        wal_changed = wal_before[p] != (os.stat(w).st_mtime_ns if os.path.exists(w) else 0)
        b = snapshot(p)
        print("%s: rows %d->%d (delta %d), max_id %d->%d (delta %d), wal_modified=%s"
              % (p, a[p][0], b[0], b[0] - a[p][0], a[p][1], b[1], b[1] - a[p][1], wal_changed))
        if b[1] != a[p][1]:
            print("  -> new persistent log rows detected")
        elif wal_changed:
            print("  -> WAL activity, but no new log rows")
        else:
            print("  -> no persistent log writes detected in sample")


def cmd_fix(dbs):
    for p in dbs:
        c = sqlite3.connect(p, timeout=30)
        try:
            if not c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='logs'").fetchone():
                print("%s: no logs table, skipped" % p)
                continue
            c.execute("CREATE TRIGGER IF NOT EXISTS block_log_inserts "
                      "BEFORE INSERT ON logs BEGIN SELECT RAISE(IGNORE); END;")
            c.commit()
            print("%s: block_log_inserts installed" % p)
        finally:
            c.close()


def cmd_undo(dbs):
    for p in dbs:
        c = sqlite3.connect(p, timeout=30)
        try:
            c.execute("DROP TRIGGER IF EXISTS block_log_inserts;")
            c.commit()
            print("%s: block_log_inserts removed" % p)
        finally:
            c.close()


def cmd_vacuum(dbs):
    for p in dbs:
        before = os.path.getsize(p)
        c = sqlite3.connect(p, timeout=60)
        try:
            c.execute("PRAGMA busy_timeout = 60000")
            c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            c.execute("VACUUM")
        finally:
            c.close()
        after = os.path.getsize(p)
        saved = before - after
        print("%s: %s -> %s (reclaimed %s)" % (p, human(before), human(after), human(saved)))


def main(argv):
    args = argv[1:]
    command = args[0] if args else "status"
    rest = args[1:]
    if command == "status":
        cmd_status(resolve_dbs(rest[0] if rest else None))
    elif command == "check":
        seconds, explicit = 5.0, None
        if rest:
            try:
                seconds = float(rest[0])
            except ValueError:
                explicit = rest[0]
        if len(rest) > 1:
            explicit = rest[1]
        cmd_check(resolve_dbs(explicit), seconds)
    elif command in ("fix", "undo", "vacuum"):
        {"fix": cmd_fix, "undo": cmd_undo, "vacuum": cmd_vacuum}[command](
            resolve_dbs(rest[0] if rest else None))
    else:
        sys.exit(USAGE.strip())


if __name__ == "__main__":
    main(sys.argv)
