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
  opened read-only (`harlequin -r transform/transform.duckdb`) from its own venv
  (`~/.venvs/harlequin`, with `duckdb` pinned to the version that wrote the file
  — currently 1.5.5). Do **not** kill the user's live Harlequin — ask them to
  quit it; only terminate a leftover process they've confirmed is closed.
- A full `dbt build` is ~4 min (re-reads the git clone + mbox cache). Use
  `dbt build --select <models>` while iterating; do one full build to confirm.
- SQL is gated by sqlfluff (per-edit `.claude/hooks/sqlfluff-lint.sh` +
  pre-commit). Recurring snags: macOS `sed` has no `\b`; rule ST09 wants a join
  `ON` condition to lead with the earlier table (or an expression), not the
  joined table's bare column; reserved words (`out`, `map`, `year`, `month`,
  `quarter`) can't be bare aliases/columns; `GROUP BY ALL` can't combine with
  `QUALIFY` (enumerate the columns there).

## Design decisions worth remembering
- **Identity resolution is connected-components.** `macros/person_node.sql`
  yields a per-(email,name) node key; `int_person_map` merges nodes that share a
  normalized email OR name (transitively, à la `int_fix_groups`) into one
  `person_key`. Facts compute the node key and JOIN `int_person_map`;
  `dim_person`, `dim_bug` reporters, and `fct_commits` authors all resolve
  through it. Real patch authors come from the commit body's `Author:` trailer,
  real bug reporters from the form body's `Logged by:` — not the git `%an` /
  From headers.
- **`fct_messages` has NO derived CSV twin** by design (one row per archived
  message, ~40 MB) — see the exclusion list in `macros/export_marts_csv.sql`.
  Query it in the warehouse, not `data/derived/`.
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
