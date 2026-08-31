#!/bin/bash
# PreToolUse hook for Bash: block in-place edits of lint-gated source files
# (.sql/.py) done through the shell, and steer them to the Edit/Write tools.
#
# WHY: the PostToolUse sqlfluff/ruff/pyright hooks match on the Write|Edit
# tools only. A `sed -i`, a `>`/`>>` redirect, a `tee`, or a `cat > f.sql`
# heredoc is a Bash tool call, so it slips past those linters entirely and the
# violation isn't caught until the pre-commit gate. This guard closes that hole
# deterministically — it doesn't rely on the assistant remembering to prefer
# Edit/Write, so it holds across every future session.
#
# It matches ONLY shell WRITES to .sql/.py:
#   - sed -i ... <file>.sql|.py
#   - > / >> / tee redirection whose target ends in .sql|.py (heredocs included)
# Reads (sed -n, cat, grep, head) and tools that rewrite files themselves
# (sqlfluff fix, ruff format, dbt) don't use these forms, so they pass. Scratch
# targets (/tmp, scratch/, .cache/) are exempt. Blocks with exit 2 (stderr ->
# Claude). BSD-grep-safe: no \b (use a non-alnum / end-of-string boundary).
#
# False-positive avoidance: git commands are skipped outright (they never edit
# source via sed/redirect, but their messages/args routinely mention .py/.sql
# filenames), and the match runs against a copy with quoted spans and "->"
# arrows stripped, so a .py/.sql inside a sed s/// script, a quoted string, or
# an arrow ("step 1 -> foo.py") isn't read as a redirect/sed target. Real
# redirect and sed file targets are unquoted, so they survive the stripping.

set -u

cmd=$(jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

# git never edits source files through sed/redirect — skip (avoids commit
# messages and git args that mention .py/.sql filenames tripping the guard).
printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|(])git[[:space:]]' && exit 0

# Strip quoted spans and -> arrows before matching (see header).
scan=$(printf '%s' "$cmd" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g; s/->//g")

ext='\.(sql|py)([^[:alnum:]]|$)'
violation=""

# sed -i on a source file
if printf '%s' "$scan" | grep -Eq 'sed[[:space:]]+-i' \
  && printf '%s' "$scan" | grep -Eiq "$ext"; then
  violation="sed -i on a .sql/.py file"
fi

# redirection / tee / heredoc whose target is a source file
if printf '%s' "$scan" | grep -Eq "(>>?[[:space:]]*|tee[[:space:]]+(-a[[:space:]]+)?)[^[:space:]|&>]*${ext}"; then
  violation="a shell redirect/tee writing a .sql/.py file"
fi

[ -z "$violation" ] && exit 0

# Exempt throwaway/scratch paths.
if printf '%s' "$scan" | grep -Eq '(/tmp/|scratchpad|(^|[[:space:]./])scratch/|\.cache/)'; then
  exit 0
fi

echo "Blocked ${violation}. Editing lint-gated source files through the shell bypasses the per-edit sqlfluff/ruff/pyright hooks (they fire only on the Edit/Write tools), so violations aren't caught until commit time. Use the Edit or Write tool instead — it does everything sed can (Edit has replace_all) and runs the linters immediately. For genuine throwaway files, write them under scratch/ or /tmp/." >&2
exit 2
