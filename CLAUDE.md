# Working notes for AI assistants in this repo

The `README.md` is the authority on architecture and conventions. This file
holds working preferences, operational gotchas, and forward-looking notes —
things that would otherwise be lost between sessions. (Use this file instead of
per-session memories, which aren't committed to git.)

## Commits
- **Never `git commit` or push without asking first and getting explicit
  confirmation.** Finish and verify the work (dbt build / tests / lint), leave
  it uncommitted, and propose a commit message — then wait.
- Commit-message trailers this repo uses are set by the environment; keep them.

## Operational gotchas
- **DuckDB is single-writer.** `transform/transform.duckdb` may be held open by
  an interactive session (Harlequin, `duckdb` CLI); a `dbt build` (read-write)
  then fails with a lock error. Quit those before building. Harlequin should be
  opened read-only from its own venv (`~/.venvs/harlequin`, with `duckdb` pinned
  to the version that wrote the file — currently 1.5.5) and **from `transform/`**
  (`cd transform && harlequin -r transform.duckdb`) — see the cwd gotcha below.
  Do **not** kill the user's live Harlequin — ask them to quit it; only
  terminate a leftover process they've confirmed is closed. Note the sqlfluff
  lint now uses the **dbt templater** (so package macros like
  `dbt_date.get_base_dates` expand) — it compiles the project per run, so a
  write-locked DuckDB breaks *linting* too, not just builds. `requirements.txt`
  pins `sqlfluff-templater-dbt` in lockstep with `sqlfluff`.
- A full `dbt build` re-reads the git clone + mbox cache each run. The mbox
  parse (`raw_list_messages` via `sources/mail.py`) is the dominant cost and now
  fans out across a process `Pool` (spawn — the parent is multithreaded, so fork
  is unsafe), ~6x faster (~257s -> ~43s); `raw_commit_files` (git side) is the
  next-slowest and still serial. Use `dbt build --select <models>` while
  iterating; do one full build to confirm.
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

## Coding conventions
- **No hardcoded dates or magic numbers** (other than `0` and `1`) in `.sql`
  or `.py`. Before writing a literal, **check `transform/vars.yml`** for an
  existing variable and use `{{ var('...') }}` — analysis knobs
  (`scheduled_release_min_items`, `release_cadence_days`, the `*_window_days`,
  the sentinel `past_eternity` / `future_eternity` dates, the date-spine bounds,
  etc.) all live there so a change means the same thing everywhere and is a
  reviewed edit. If the constant you need isn't a var yet, add it to `vars.yml`
  rather than inlining it. The sentinel `1900-01-01` / `9999-01-01` are
  `var('past_eternity')` / `var('future_eternity')`; a "< N items" or "N days"
  threshold is almost always already a var.

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
- **Surrogate keys: every non-date dimension's PK is its first column, named
  `<table>_key`** (`dim_release_key`, `dim_version_key`, `dim_bug_key`,
  `dim_cve_key`, `dim_person_key`), a `dbt_utils.generate_surrogate_key` hash
  computed ONCE, in the dimension. Facts/bridges get the FK by JOINing the dim on
  the natural key and selecting its `<table>_key` — never recompute the hash in
  the fact. Role-prefix where a fact references one dim twice
  (`author_dim_person_key`, `primary_dim_bug_key`, `ship_dim_release_key`). Dims
  keep the natural key as a plain attribute (`version`, `bug_number`, `cve_id`).
  `dim_person_key` is `int_person_map`'s connected-component id surfaced under
  the convention (NOT a fresh hash — that would break identity resolution).
  **`dim_date` is the deliberate exception:** no surrogate — facts store the DATE
  and join on `dim_date.date_day`.
- **Kimball special members (no NULL FKs).** Every non-date dimension carries two
  extra rows (`macros/dim_special_members.sql`): **Unknown**
  (`unknown_key()` = `generate_surrogate_key('-1')`) and **Not Applicable**
  (`not_applicable_key()` = `'-2'`). A fact's LEFT-JOINed FK is COALESCEd so it's
  never NULL — mandatory FKs to Unknown (a resolution failure), legitimately-
  absent optional FKs to Not Applicable (no bug, `.0` major, pre-corpus). The
  `not_unknown_member` generic test guards each mandatory FK (errors if one lands
  on Unknown). A special row's placeholder attributes that can't satisfy an
  attribute test (`accepted_values`, a `not_null`, a regex) are exempted with a
  `config: where:` filtered on the placeholder natural key (e.g. `status NOT IN
  ('unknown','not applicable')`) — dbt forbids a macro in a test's `where`.
  `dim_date`'s equivalents are its real `past_eternity` (1900-01-01) /
  `future_eternity` (9999-01-01) rows (vars). Append special rows with an
  explicit-column `UNION ALL` — NOT `UNION ALL BY NAME` (sqlfluff AM07 can't
  parse it).
- A **release cycle** and a **release** are the same entity at two lifecycle stages
  (a release is a shipped cycle), unified in **`dim_release`** (`status` =
  shipped/open/future; shipped measures NULL for non-shipped). The cycle signals
  (`cycle_start_dt`, `window_days`, `early_*_cnt`, `full_fix_cnt`, from
  `int_release_cycles`) are **folded onto the same row** — a cycle was a fact 1:1
  with this dimension, so `fct_release_cycles` was retired into it; they're
  non-NULL only for the started scheduled cycles (`cycle_start_dt IS NOT NULL`).
  `fct_fixes.dim_release_key` conforms to `dim_release.dim_release_key`.
  `dim_release.release_dt` is the release day — the changelog aliases it back to
  `release_dt` for its charts.