#!/bin/bash
# PostToolUse hook for Edit|Write: lint .sql files with sqlfluff (duckdb
# dialect + jinja templater, config in the repo-root .sqlfluff) from the
# project venv. Report-only — surfaces violations back to Claude via
# additionalContext; stays silent when the file is clean or isn't SQL.
#
# Assumes Claude Code's cwd is the project root (i.e. ./venv/bin/sqlfluff and
# .sqlfluff resolve from here). Mirrors ruff-lint.sh next to it; the matching
# blocking commit-time gate is the sqlfluff hook in .pre-commit-config.yaml.

set -u

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
  jq -n --arg ctx "sqlfluff violations in ${f}:
${output}" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
fi
