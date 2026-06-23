@echo off
setlocal EnableExtensions

set "ACTION=%~1"
if not defined ACTION set "ACTION=status"
set "SECONDS=%~2"
if not defined SECONDS set "SECONDS=5"

if defined CODEX_HOME (
  set "DB=%CODEX_HOME%\logs_2.sqlite"
) else (
  set "DB=%USERPROFILE%\.codex\logs_2.sqlite"
)

if not exist "%DB%" (
  echo ERROR: Codex log database not found: "%DB%" 1>&2
  exit /b 2
)

where py >nul 2>&1
if not errorlevel 1 (
  set "PY=py -3"
  goto python_found
)
where python >nul 2>&1
if not errorlevel 1 (
  set "PY=python"
  goto python_found
)
echo ERROR: Python 3 is required. Neither "py -3" nor "python" was found. 1>&2
exit /b 3

:python_found
if /I "%ACTION%"=="status" goto status
if /I "%ACTION%"=="check" goto check
if /I "%ACTION%"=="fix" goto fix
if /I "%ACTION%"=="undo" goto undo
goto usage

:status
where codex >nul 2>&1 && call codex --version
%PY% -c "import os,sqlite3,sys; p=sys.argv[1]; c=sqlite3.connect(p,timeout=10); levels=c.execute('SELECT level, COUNT(*) FROM logs GROUP BY level ORDER BY COUNT(*) DESC').fetchall(); total,max_id=c.execute('SELECT COUNT(*), COALESCE(MAX(id),0) FROM logs').fetchone(); trigger=c.execute(\"SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='block_log_inserts'\").fetchone()[0]; print('Database:',p); print('Database bytes:',os.path.getsize(p)); print('WAL bytes:',os.path.getsize(p+'-wal') if os.path.exists(p+'-wal') else 0); print('Rows:',total); print('Max id:',max_id); print('Levels:',', '.join(str(k)+'='+str(v) for k,v in levels)); print('Fix trigger:','installed' if trigger else 'not installed'); c.close()" "%DB%"
exit /b %errorlevel%

:check
echo Keep Codex actively streaming while this %SECONDS%-second check runs.
%PY% -c "import os,sqlite3,sys,time; p=sys.argv[1]; delay=float(sys.argv[2]); snap=lambda:(sqlite3.connect(p,timeout=10).execute('SELECT COUNT(*), COALESCE(MAX(id),0) FROM logs').fetchone(), os.stat(p+'-wal').st_mtime_ns if os.path.exists(p+'-wal') else 0, os.path.getsize(p+'-wal') if os.path.exists(p+'-wal') else 0); a=snap(); time.sleep(delay); b=snap(); changed=b[0][1] != a[0][1]; wal_changed=b[1] != a[1]; print('Rows:',a[0][0],'->',b[0][0],'delta=',b[0][0]-a[0][0]); print('Max id:',a[0][1],'->',b[0][1],'delta=',b[0][1]-a[0][1]); print('WAL bytes:',a[2],'->',b[2]); print('WAL modified:',wal_changed); print('Result:','new persistent log rows detected' if changed else ('WAL activity detected, but no new log rows' if wal_changed else 'no persistent log writes detected in sample'))" "%DB%" "%SECONDS%"
exit /b %errorlevel%

:fix
echo Installing block_log_inserts in "%DB%"...
%PY% -c "import sqlite3,sys; p=sys.argv[1]; c=sqlite3.connect(p,timeout=30); assert c.execute(\"SELECT 1 FROM sqlite_master WHERE type='table' AND name='logs'\").fetchone(), 'logs table not found'; c.execute('CREATE TRIGGER IF NOT EXISTS block_log_inserts BEFORE INSERT ON logs BEGIN SELECT RAISE(IGNORE); END;'); c.commit(); print('Fix installed. Persistent diagnostic log inserts are now blocked.'); c.close()" "%DB%"
exit /b %errorlevel%

:undo
echo Removing block_log_inserts from "%DB%"...
%PY% -c "import sqlite3,sys; p=sys.argv[1]; c=sqlite3.connect(p,timeout=30); c.execute('DROP TRIGGER IF EXISTS block_log_inserts;'); c.commit(); print('Fix removed. Persistent diagnostic logging is enabled again.'); c.close()" "%DB%"
exit /b %errorlevel%

:usage
echo Usage: %~nx0 ^<status^|check [seconds]^|fix^|undo^>
exit /b 1
