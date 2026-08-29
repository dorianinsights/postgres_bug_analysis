#!/bin/bash
# PostToolUse hook for Edit|Write: type-check .py files with pyright from the
# project venv. Surfaces errors back to Claude via additionalContext; stays
# silent when the file is clean or isn't Python.
#
# Assumes Claude Code's cwd is the project root (i.e. that ./venv/bin/pyright
# and pyproject.toml [tool.pyright] resolve from here).
#
# Two things to know about this one, versus the ruff hook next to it:
#
#  - It is SLOW by comparison (seconds, not milliseconds). pyright loads the
#    whole project's config and dependency graph even to check a single file;
#    that cost is inherent, not a misconfiguration. Hence the larger timeout.
#  - It is single-file, so it catches breakage IN the edited file only. An
#    edit here that breaks a DIFFERENT module (changing a function's return
#    type, say) is caught by the blocking pre-commit gate, not by this hook.
#
# pyright self-filters paths excluded in [tool.pyright] (an explicitly-passed
# excluded file reports filesAnalyzed=0), so no exclude handling is needed.
# See .pre-commit-config.yaml for the matching commit-time gate.

set -u

f=$(jq -r '.tool_input.file_path // empty')

case "$f" in
  *.py) ;;
  *) exit 0 ;;
esac

# Skip files that no longer exist (e.g. edited then removed in the same turn).
[ -f "$f" ] || exit 0

json=$(env -u FORCE_COLOR -u CLICOLOR_FORCE NO_COLOR=1 \
  ./venv/bin/pyright --outputjson "$f" 2>/dev/null)

# A non-zero exit with unparseable output means pyright itself failed to run
# (missing venv, bad config). Stay silent rather than spamming every edit.
echo "$json" | jq -e . >/dev/null 2>&1 || exit 0

count=$(echo "$json" | jq '[.generalDiagnostics[] | select(.severity == "error")] | length')
[ "$count" -eq 0 ] && exit 0

output=$(echo "$json" | jq -r '
  .generalDiagnostics[]
  | select(.severity == "error")
  | "  \(.range.start.line + 1):\(.range.start.character + 1) \(.message | split("\n")[0])\(if .rule then " (\(.rule))" else "" end)"
')

jq -n --arg ctx "pyright errors in ${f}:
${output}" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
