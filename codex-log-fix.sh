#!/usr/bin/env sh
set -eu

action="${1:-status}"
seconds="${2:-5}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
db="$codex_home/logs_2.sqlite"

if [ ! -f "$db" ]; then
  echo "ERROR: Codex log database not found: $db" >&2
  exit 2
fi

if command -v python3 >/dev/null 2>&1; then
  python_cmd=python3
elif command -v python >/dev/null 2>&1; then
  python_cmd=python
else
  echo "ERROR: Python 3 is required. Neither python3 nor python was found." >&2
  exit 3
fi

case "$action" in
  status)
    command -v codex >/dev/null 2>&1 && codex --version || true
    "$python_cmd" -c 'import os,sqlite3,sys; p=sys.argv[1]; c=sqlite3.connect(p,timeout=10); levels=c.execute("SELECT level, COUNT(*) FROM logs GROUP BY level ORDER BY COUNT(*) DESC").fetchall(); total,max_id=c.execute("SELECT COUNT(*), COALESCE(MAX(id),0) FROM logs").fetchone(); trigger=c.execute("SELECT COUNT(*) FROM sqlite_master WHERE type=\"trigger\" AND name=\"block_log_inserts\"").fetchone()[0]; print("Database:",p); print("Database bytes:",os.path.getsize(p)); print("WAL bytes:",os.path.getsize(p+"-wal") if os.path.exists(p+"-wal") else 0); print("Rows:",total); print("Max id:",max_id); print("Levels:",", ".join(str(k)+"="+str(v) for k,v in levels)); print("Fix trigger:","installed" if trigger else "not installed"); c.close()' "$db"
    ;;
  check)
    echo "Keep Codex actively streaming while this ${seconds}-second check runs."
    "$python_cmd" -c 'import os,sqlite3,sys,time; p=sys.argv[1]; delay=float(sys.argv[2]); snap=lambda:(sqlite3.connect(p,timeout=10).execute("SELECT COUNT(*), COALESCE(MAX(id),0) FROM logs").fetchone(), os.stat(p+"-wal").st_mtime_ns if os.path.exists(p+"-wal") else 0, os.path.getsize(p+"-wal") if os.path.exists(p+"-wal") else 0); a=snap(); time.sleep(delay); b=snap(); changed=b[0][1] != a[0][1]; wal_changed=b[1] != a[1]; print("Rows:",a[0][0],"->",b[0][0],"delta=",b[0][0]-a[0][0]); print("Max id:",a[0][1],"->",b[0][1],"delta=",b[0][1]-a[0][1]); print("WAL bytes:",a[2],"->",b[2]); print("WAL modified:",wal_changed); print("Result:","new persistent log rows detected" if changed else ("WAL activity detected, but no new log rows" if wal_changed else "no persistent log writes detected in sample"))' "$db" "$seconds"
    ;;
  fix)
    echo "Installing block_log_inserts in $db..."
    "$python_cmd" -c 'import sqlite3,sys; p=sys.argv[1]; c=sqlite3.connect(p,timeout=30); assert c.execute("SELECT 1 FROM sqlite_master WHERE type=\"table\" AND name=\"logs\"").fetchone(), "logs table not found"; c.execute("CREATE TRIGGER IF NOT EXISTS block_log_inserts BEFORE INSERT ON logs BEGIN SELECT RAISE(IGNORE); END;"); c.commit(); print("Fix installed. Persistent diagnostic log inserts are now blocked."); c.close()' "$db"
    ;;
  undo)
    echo "Removing block_log_inserts from $db..."
    "$python_cmd" -c 'import sqlite3,sys; p=sys.argv[1]; c=sqlite3.connect(p,timeout=30); c.execute("DROP TRIGGER IF EXISTS block_log_inserts;"); c.commit(); print("Fix removed. Persistent diagnostic logging is enabled again."); c.close()' "$db"
    ;;
  *)
    echo "Usage: $0 <status|check [seconds]|fix|undo>" >&2
    exit 1
    ;;
esac
