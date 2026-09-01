#!/bin/bash
# PostToolUse hook for Edit|Write: validate dbt-charts (dct) boards under
# transform/faces/ with `dct validate` from the project venv. Blocking (exit 2)
# -- surfaces YAML-schema / cross-reference errors back to Claude on stderr so
# the edit must be fixed before continuing; stays silent when the board is clean
# or the file isn't a faces board. Scoped to transform/faces/ (and any
# subfolders) so it never fires on the dbt project's model schema .yml files.
# dct validate needs
# no database connection. The matching commit-time gate is the dct-validate
# hook in .pre-commit-config.yaml.
#
# Mirrors sqlfluff-lint.sh next to it. dct resolves its project by walking up
# from the cwd, so this runs from transform/ (where dbt_charts.yml sits beside
# dbt_project.yml); the venv is one level up at ../venv.

set -u

# cd to transform/ (the dct + dbt project root), resolved from this script's own
# path, so dbt_charts.yml resolves regardless of the invoking cwd.
cd "$(dirname "${BASH_SOURCE[0]}")/../../transform" || exit 0

f=$(jq -r '.tool_input.file_path // empty')

# Only transform/faces/ boards. In bash `case`, * spans '/', so these also match
# any subfolder under it. Handles both absolute and repo-relative paths.
case "$f" in
  */transform/faces/*.yml | */transform/faces/*.yaml | transform/faces/*.yml | transform/faces/*.yaml) ;;
  *) exit 0 ;;
esac

# Skip files that no longer exist (e.g. edited then removed in the same turn).
[ -f "$f" ] || exit 0

output=$(env -u FORCE_COLOR -u CLICOLOR_FORCE NO_COLOR=1 ../venv/bin/dct validate "$f" 2>&1)
status=$?

if [ "$status" -ne 0 ]; then
  echo "dct validate errors in ${f} — fix before continuing:
${output}" >&2
  exit 2
fi
