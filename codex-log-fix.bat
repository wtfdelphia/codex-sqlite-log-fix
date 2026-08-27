@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"

if not exist "%SCRIPT_DIR%codex_log_fix.py" (
  echo ERROR: codex_log_fix.py not found next to this script. 1>&2
  exit /b 2
)

where py >nul 2>&1
if not errorlevel 1 (
  set "PY=py -3"
  goto run
)
where python >nul 2>&1
if not errorlevel 1 (
  set "PY=python"
  goto run
)
echo ERROR: Python 3 is required. Neither "py -3" nor "python" was found. 1>&2
exit /b 3

:run
%PY% "%SCRIPT_DIR%codex_log_fix.py" %*
exit /b %errorlevel%
