#!/bin/bash
# PostToolUse hook for Edit|Write: format then lint .py files with ruff from
# the project venv. Blocking (exit 2) — surfaces lint violations back to Claude
# on stderr so the edit must be fixed before continuing; stays silent when the
# file is clean or isn't Python.
#
# Assumes Claude Code's cwd is the project root (i.e. that ./venv/bin/ruff
# and pyproject.toml [tool.ruff] resolve from here).

set -u

# cd to the repo root (resolved from this script's own path) so ./venv and
# pyproject.toml resolve regardless of the invoking cwd
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 0

f=$(jq -r '.tool_input.file_path // empty')

case "$f" in
  *.py) ;;
  *) exit 0 ;;
esac

# Keep edits formatted (ruff format is semantics-preserving; respects
# force-exclude for excluded dirs).
./venv/bin/ruff format --quiet "$f" 2>/dev/null

output=$(env -u FORCE_COLOR -u CLICOLOR_FORCE NO_COLOR=1 ./venv/bin/ruff check --output-format concise "$f" 2>&1)
status=$?

if [ "$status" -ne 0 ]; then
  echo "ruff violations in ${f} — fix before continuing:
${output}" >&2
  exit 2
fi
