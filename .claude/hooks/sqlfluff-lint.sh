#!/bin/bash
# PostToolUse hook for Edit|Write: lint .sql files with sqlfluff (duckdb
# dialect + jinja templater, config in the repo-root .sqlfluff) from the
# project venv. Blocking (exit 2) — surfaces violations back to Claude on
# stderr so the edit must be fixed before continuing; stays silent when the
# file is clean or isn't SQL.
#
# Assumes Claude Code's cwd is the project root (i.e. ./venv/bin/sqlfluff and
# .sqlfluff resolve from here). Mirrors ruff-lint.sh next to it; the matching
# blocking commit-time gate is the sqlfluff hook in .pre-commit-config.yaml.

set -u

# cd to the repo root (resolved from this script's own path) so ./venv,
# .sqlfluff, and its macro path resolve regardless of the invoking cwd
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 0

f=$(jq -r '.tool_input.file_path // empty')

case "$f" in
  *.sql) ;;
  *) exit 0 ;;
esac

# Skip files that no longer exist (e.g. edited then removed in the same turn).
[ -f "$f" ] || exit 0

output=$(env -u FORCE_COLOR -u CLICOLOR_FORCE NO_COLOR=1 ./venv/bin/sqlfluff lint "$f" 2>&1)
status=$?

if [ "$status" -ne 0 ]; then
  echo "sqlfluff violations in ${f} — fix before continuing:
${output}" >&2
  exit 2
fi
