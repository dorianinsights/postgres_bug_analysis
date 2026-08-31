# Working notes for AI assistants in this repo

The `README.md` is the authority on architecture and conventions. This file
holds working preferences, operational gotchas, and forward-looking notes —
things that would otherwise be lost between sessions. (Use this file instead of
per-session memories, which aren't committed to git.)

## Commits
- **Never `git commit` or push without asking first and getting explicit
  confirmation.** Finish and verify the work (dbt build / tests / lint), leave
  it uncommitted, and propose a commit message — then wait. (Standing rule as of
  2026-08-29; supersedes any earlier "commit the outstanding work" requests.)
- Commit-message trailers this repo uses are set by the environment; keep them.

## Operational gotchas
- **DuckDB is single-writer.** `transform/transform.duckdb` may be held open by
  an interactive session (Harlequin, `duckdb` CLI); a `dbt build` (read-write)
  then fails with a lock error. Quit those before building. Harlequin should be
  opened read-only from its own venv (`~/.venvs/harlequin`, with `duckdb` pinned
  to the version that wrote the file — currently 1.5.5) and **from `transform/`**
  (`cd transform && harlequin -r transform.duckdb`) — see the cwd gotcha below.
  Do **not** kill the user's live Harlequin — ask them to quit it; only
  terminate a leftover process they've confirmed is closed.
- A full `dbt build` is ~4 min (re-reads the git clone + mbox cache). Use
  `dbt build --select <models>` while iterating; do one full build to confirm.
- **Edit `.sql`/`.py` files with the Edit/Write tools — never `sed -i`, a `>`
  redirect, or a `cat >` heredoc through Bash** (even in "auto mode", which
  otherwise nudges toward `sed`). The per-edit linters below are `PostToolUse`
  hooks matched on the `Write|Edit` tools, so a shell edit slips past them and
  the violation isn't caught until the pre-commit gate. A `PreToolUse` Bash
  guard (`.claude/hooks/bash-source-edit-guard.sh`) enforces this — it blocks
  shell writes to `.sql`/`.py` (reads, `sqlfluff fix`/`ruff format`, and
  `scratch/`|`/tmp/` targets pass). Edit does everything `sed` can (`replace_all`
  for bulk). `.md`/`.yml`/`.csv`/`.sh` aren't gated, so Bash is fine there.
- SQL/Python are gated per-edit AND at commit. The per-edit `.claude/hooks/`
  (`sqlfluff-lint.sh`, `ruff-lint.sh`, `pyright-check.sh`) are now **blocking**
  (exit 2 on a violation — fix it in the same turn, don't defer to commit); the
  `.pre-commit-config.yaml` gate is the final backstop regardless of edit tool.
  Recurring sqlfluff snags: macOS `sed`/BSD `grep` have no `\b`; rule ST09 wants
  a join `ON` condition to lead with the earlier table (or an expression), not
  the joined table's bare column; RF02 wants every column qualified once a
  statement (incl. a scalar subquery) references more than one table; reserved
  words (`out`, `map`, `year`, `month`, `quarter`) can't be bare aliases/columns;
  `GROUP BY ALL` can't combine with `QUALIFY` (enumerate the columns there).
- **Interactive DuckDB/Harlequin must be launched from `transform/`**, not the
  repo root: the `staging.stg_*` models are *views* that read external CSVs by a
  relative path (`../data/raw/*.csv`, resolved against the process cwd — dbt runs
  from `transform/`). From the repo root they throw `IO Error: No files found`;
  `intermediate`/`marts` are real tables baked into the file and query from
  anywhere. So `cd transform && harlequin -r transform.duckdb` (or
  `duckdb -readonly transform.duckdb`).

## Design decisions worth remembering
- **Identity resolution is connected-components.** `macros/person_node.sql`
  yields a per-(email,name) node key; `int_person_map` merges nodes that share a
  normalized email OR name (transitively, à la `int_fix_groups`) into one
  `person_key`. Facts compute the node key and JOIN `int_person_map`;
  `dim_person`, `dim_bug` reporters, and `fct_commits` authors all resolve
  through it. Real patch authors come from the commit body's `Author:` trailer,
  real bug reporters from the form body's `Logged by:` — not the git `%an` /
  From headers.
- **Big marts have NO derived CSV twin** by design. `macros/export_marts_csv.sql`
  (on-run-end) writes a `data/derived/<mart>.csv` audit twin only for marts with
  fewer than `var('derived_csv_max_rows')` (1000) rows — a bigger table's diff is
  unreviewable and bloats the repo. So `fct_messages` (~160k), `fct_commits`,
  `dim_person`, `dim_date`, `dim_bug`, and `fct_fixes` have no CSV; query them in
  the warehouse, not `data/derived/`. The gate skips *writing* but can't *delete*,
  so if a mart grows past the threshold, `git rm` its now-stale CSV once.
- **Naming: dimensions singular, facts plural** is intentional (Kimball). Don't
  "fix" `fct_*` to singular.
- A **release cycle** and a **wave** are the same entity at two lifecycle stages
  (a wave is a shipped cycle), unified in **`dim_release`** (`status` =
  shipped/open/future; measures NULL for non-shipped). `fct_release_cycles` is
  the cycle-grain fact and `fct_fixes.wave_key` both conform to
  `dim_release.release_key`. `dim_release.release_dt` is the release day — the
  changelog aliases it back to `wave_dt` for its charts.

## Known future work (not done)
- **Person alias seed.** The automatic name/email merge can't unify identities
  that use a different name AND a different email with no overlap. A curated
  `seeds/person_aliases.csv` (auto-seeded from collisions, then hand-reviewed)
  would catch those.
- Bug-reporter display names are occasionally junk (~19 of 1,952) because
  reporters typed non-name text into the form's "Logged by:" field — a
  source-data quality issue, not a parse bug. Identity is email-keyed, so
  resolution is unaffected; only the `canonical_name` is off for those.
