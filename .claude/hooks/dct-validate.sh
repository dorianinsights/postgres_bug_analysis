#!/bin/bash
# PostToolUse hook for Edit|Write: validate dbt-charts (dct) boards under
# faces/ with `dct validate` from the project venv. Blocking (exit 2) --
# surfaces YAML-schema / cross-reference errors back to Claude on stderr so the
# edit must be fixed before continuing; stays silent when the board is clean or
# the file isn't a faces board. Scoped to faces/ (and any subfolders) so it
# never fires on the dbt project's model schema .yml files. dct validate needs
# no database connection. The matching commit-time gate is the dct-validate
# hook in .pre-commit-config.yaml.
#
# Assumes Claude Code's cwd is the project root (./venv/bin/dct and
# dbt_charts.yml resolve from here). Mirrors sqlfluff-lint.sh next to it.

set -u

# cd to the repo root (resolved from this script's own path) so ./venv and
# dbt_charts.yml resolve regardless of the invoking cwd.
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 0

f=$(jq -r '.tool_input.file_path // empty')

# Only faces/ boards. In bash `case`, * spans '/', so these also match any
# subfolder under faces/. Handles both absolute and repo-relative paths.
case "$f" in
  */faces/*.yml | */faces/*.yaml | faces/*.yml | faces/*.yaml) ;;
  *) exit 0 ;;
esac

# Skip files that no longer exist (e.g. edited then removed in the same turn).
[ -f "$f" ] || exit 0

output=$(env -u FORCE_COLOR -u CLICOLOR_FORCE NO_COLOR=1 ./venv/bin/dct validate "$f" 2>&1)
status=$?

if [ "$status" -ne 0 ]; then
  echo "dct validate errors in ${f} — fix before continuing:
${output}" >&2
  exit 2
fi
