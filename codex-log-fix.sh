#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
helper="$script_dir/codex_log_fix.py"

if [ ! -f "$helper" ]; then
  echo "ERROR: codex_log_fix.py not found next to this script." >&2
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

exec "$python_cmd" "$helper" "$@"
