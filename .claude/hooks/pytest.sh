#!/bin/bash
# PostToolUse hook for Edit|Write: run the pytest suite when a .py file changes.
# Blocking (exit 2) — a failing test surfaces back to Claude on stderr so it's
# fixed in the same turn, mirroring the ruff/pyright per-edit hooks and the
# pre-commit gate. Stays silent when the edit isn't Python (or is a vendored /
# generated / cached file nothing tests). The suite is fast (~0.1s) and scoped
# to tests/ via pyproject testpaths, so it runs WHOLE — a change anywhere can
# break a test elsewhere.
#
# Assumes Claude Code's cwd is the project root (./venv/bin/pytest and
# pyproject.toml [tool.pytest.ini_options] resolve from here).

set -u

# cd to the repo root (resolved from this script's own path) so ./venv and
# pyproject.toml resolve regardless of the invoking cwd.
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 0

f=$(jq -r '.tool_input.file_path // empty')

case "$f" in
  *.py) ;;
  *) exit 0 ;;
esac

# Nothing under these trees is under test — skip so an unrelated edit there
# doesn't trigger a run.
case "$f" in
  */venv/*|*/target/*|*/dbt_packages/*|*/.cache/*) exit 0 ;;
esac

output=$(env -u FORCE_COLOR -u CLICOLOR_FORCE NO_COLOR=1 ./venv/bin/pytest 2>&1)
status=$?

if [ "$status" -ne 0 ]; then
  echo "pytest failures after editing ${f} — fix before continuing:
${output}" >&2
  exit 2
fi
