# Working notes for AI assistants in this repo

The `README.md` is the authority on architecture and conventions. This file
holds working preferences, operational gotchas, and forward-looking notes —
things that would otherwise be lost between sessions. (Use this file instead of
per-session memories, which aren't committed to git.)

## Commits
- **Never `git commit` or push without asking first and getting explicit
  confirmation.** Finish and verify the work (dbt build / tests / lint), leave
  it uncommitted, and propose a commit message — then wait.
- **Commit directly on `main`. Do NOT create feature branches** — the user works
  trunk-based here; don't branch before committing even though `main` is the
  default branch.
- Commit-message trailers this repo uses are set by the environment; keep them.

## Operational gotchas
- **The Python side is one editable-installed package, `pg_analysis`**
  (`python/pg_analysis/`: `corpus`, `paths`, the fetchers, `refresh_data`, the
  backfills, `embed_fixes`, and `sources/` — the readers the dbt Python models
  import). `requirements.txt` ends with `-e .`, so a fresh venv gets it from
  `pip install -r requirements.txt`; the `pg-*` console scripts
  (`pg-refresh`, `pg-clone`, `pg-mail-sync`, `pg-cve-scrape`,
  `pg-backfill-ai`, `pg-backfill-categories`, `pg-embed-fixes`) land in
  `venv/bin` from `[project.scripts]`. **Every import is an ordinary
  `from pg_analysis... import`** — the dbt models, the tests, the backfills:
  never add a `sys.path.insert` or a `Path(__file__)`/`Path.cwd()` anchor.
  **Every repo path comes from `pg_analysis.paths`** (`REPO_ROOT`, `CLONE`,
  `MBOX_CACHE`, `DATA_RAW`, `DBT_PROJECT_DIR`, `SEEDS_DIR`, `WAREHOUSE`,
  `ENV_FILE`); it locates the repo from its own file, which is why the install
  must stay editable (a non-editable install would resolve to site-packages
  and find nothing). Adding a runnable module = add its `main()` to
  `[project.scripts]`; the venv picks it up on the next `pip install -e .`.
  `refresh_data` calls the fetch modules' `main()` in-process (a step fails
  when `main()` raises; only dbt is a subprocess), so a fetch's failure
  signal must stay an exception or `SystemExit`, never a bare `return`
  after printing an error.
- **DuckDB is single-writer.** `transform.duckdb` (at the repo root) may be held open by
  an interactive session (Harlequin, `duckdb` CLI); a `dbt build` (read-write)
  then fails with a lock error. Quit those before building. Harlequin should be
  opened read-only from its own venv (`~/.venvs/harlequin`, with `duckdb` pinned
  to the version that wrote the file — currently 1.5.5) and **from the repo
  root** (`harlequin -r transform.duckdb`) — see the cwd gotcha below.
  Do **not** kill the user's live Harlequin — ask them to quit it; only
  terminate a leftover process they've confirmed is closed. Note the sqlfluff
  lint now uses the **dbt templater** (so package macros like
  `dbt_date.get_base_dates` expand) — it compiles the project per run, so a
  write-locked DuckDB breaks *linting* too, not just builds. `requirements.txt`
  pins `sqlfluff-templater-dbt` in lockstep with `sqlfluff`.
- A full `dbt build` re-reads the git clone + mbox cache each run. The mbox
  parse (`raw_list_messages` via `pg_analysis.sources.mail`) is the dominant cost and now
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
  **Marts end in an explicit column list, never `SELECT *`** (in the final
  SELECT and every top-level UNION branch): `dct validate` derives a model's
  columns statically from that projection to check the boards' queries, and a
  wildcard makes the model unresolvable. Not lint-enforced; run
  `dct validate --strict charts/*.yml` now and then to surface
  any `WARN-DBT-MODEL-COLUMNS-UNRESOLVED`.
- **Interactive DuckDB/Harlequin must be launched from the repo root** (the
  dbt project root): the `staging.stg_*` models are *views* that read external
  CSVs by a relative path (`data/raw/*.csv`, resolved against the process cwd,
  which is the repo root when dbt runs). From any other directory they throw
  `IO Error: No files found`; `intermediate`/`marts` are real tables baked into
  the file and query from anywhere. So, from the root,
  `harlequin -r transform.duckdb` (or `duckdb -readonly transform.duckdb`).

- **dct (0.7.0): the query's ORDER BY orders a categorical axis, so do NOT
  author `sort:`** -- every board renders pixel-identical without it, and an
  authored sort key is SUMMED per x category (0.7.0 report item 3), which
  scrambles the axis whenever categories have unequal row counts. The one
  exception is a single-series HORIZONTAL bar, which defaults to
  value-descending order (`projected_fixes` `estimates` keeps its `sort:` for
  that reason). Overlay series get their own tooltip rows now, so the 0.6-era
  "one reference series per overlay" rule is gone too. The list-traffic charts
  still draw the partial current period as the last point of the main series
  (simpler than a dashed overlay tail, and the subtitle says so).
  **Board-level `style.charts` cascades like inline** for `min_height` /
  `max_height` (= one height pin per board) and `bar: { stack: ... }` (only
  on boards where EVERY bar chart is stacked -- the four mixed boards keep
  `stack:` inline; the bar block does not reach area charts), but
  `bar.orientation` is silently ignored (report item 8), so `orientation:
  vertical` stays per chart. **Share (100%-stacked) charts feed COUNTS through
  `stack: normalize` with no `axis_y` format:** the axis is labeled in percent
  anyway and the hover shows share, count and total; an authored percent axis
  format percent-formats the hover's raw count column ("2000%", report
  item 9). Faces name models with `{{ ref() }}`
  (resolved from `target/manifest.json`, so run `dbt parse` after adding or
  renaming a model or column, and `dct validate charts/*.yml` checks the
  queries' columns statically -- the marts end in explicit projections, not
  `SELECT *`, so keep it that way); before renaming a mart column, run
  `dct impact <column>` to list the boards and queries that
  read it. Rerun `dct migrate charts/` after a dct upgrade and keep its
  `_schema_version` stamp. The dct workflow skills live in the gitignored
  `.claude/skills/dct-*/` (`dct init skills claude`; rerun after an upgrade --
  it overwrites and sweeps retired skills, there is no `-f` any more).

## Coding conventions
- **No hardcoded dates or magic numbers** (other than `0` and `1`) in `.sql`
  or `.py`. Before writing a literal, **check `vars.yml`** for an
  existing variable and use `{{ var('...') }}` — analysis knobs
  (`scheduled_release_min_items`, `reversion_baseline_releases`, the `*_window_days`,
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
  `dim_person`, `dim_bug` reporters, and `dim_commit` authors all resolve
  through it. Real patch authors come from the commit body's `Author:` trailer,
  real bug reporters from the form body's `Logged by:` — not the git `%an` /
  From headers.
- **Big marts have NO derived CSV twin** by design. `macros/export_marts_csv.sql`
  (on-run-end) writes a `data/derived/<mart>.csv` audit twin only for marts with
  fewer than `var('derived_csv_max_rows')` (1000) rows — a bigger table's diff is
  unreviewable and bloats the repo. So `fct_messages` (~160k), `fct_commit_files`
  (~100k), `dim_commit` (~23k), `dim_person`, `dim_date`, `dim_bug`, and
  `fct_fixes` have no CSV; query them in the warehouse, not `data/derived/`. The gate skips *writing* but can't *delete*,
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
  parse it). **Every dimension carries a `not_null` boolean `is_synthetic_row`**
  — `true` for exactly these synthetic rows (the Unknown / Not Applicable
  members; `dim_date`'s two eternity sentinels), `false` for every real entity
  (`master`, the in-development version/release, and `dim_commit`'s rows, which
  have no special members, are all real → `false`). It is the **canonical filter
  for dropping synthetic rows in a dashboard** (`WHERE NOT is_synthetic_row`) —
  prefer it over per-dim natural-key hacks like `bug_number > 0` or
  `NOT IN ('(unknown)', ...)`.
- **One commit → release mapping, two fix populations.** `int_commit_versions`
  is the only place a commit is assigned to a version/release, trunk included:
  exact git tag ancestry gives a shipped minor (`release_status = 'shipped'`) or
  a major's `.0` (`'development'`: master between two fork points plus the
  branch's pre-GA stabilization), and a released major's stable-branch commits
  after its latest tag are pending for the OPEN release (`'open'`). Every
  branch's corpus range is tag-bounded too (`pg_analysis.sources.git.commit_range`: a
  stable branch from its fork, master from `corpus.HISTORY_FLOOR_TAG`) -- there
  is no history date anywhere. Never re-derive any of this with date windows.
  `dim_commit.branch_scope` (trunk/beta/stable) is per COMMIT from that status,
  and `int_major_development` is an aggregate of it (no separate git walk).
  **Never SUM anything per stable-branch commit across branches** (churn, file
  counts): a fix is one commit per branch it was backpatched to, and the number
  of branches inside the corpus grew from one (2021) to five (2025+), so the
  sum tracks the corpus, not the work. Sum over
  `dim_commit.is_representative_commit` (one backpatch per fix, its largest
  by churn) instead; the
  per-branch charts are comparable only from Q3 2025 on. `int_git_commits` defines `fix_key` (normalized subject —
  the identity of a fix across its backpatches) and `is_housekeeping` (stamps,
  translations, notes drafting, tz data: not fixes) once; every "distinct fix
  commits" count is `COUNT(DISTINCT fix_key) ... WHERE NOT is_housekeeping`
  (the boards read them off `dim_commit`). `int_committed_fixes` is the
  committed-fix population (grain release × fix_key) and `int_fix_reps` the
  documented one; `resolve_fix_origin` classifies both. Cycle-grain measures
  fold an out-of-band release into its cycle via
  `int_releases.cycle_ships_at_dt`; release-grain measures keep the exact
  release.
- **AI involvement is DISCLOSED involvement, read by a local LLM -- never a
  keyword filter.** `int_commit_ai_texts` (one text per `fix_key`) and
  `int_thread_ai_texts` (one per thread root) put EVERY commit and thread in
  scope; `int_commit_ai_involvement` / `int_thread_ai_involvement` (Python,
  `pg_analysis.sources.ai_involvement`) ask qwen3:30b-a3b for the four independent
  work-role flags (`ai_found` / `ai_analyzed` / `ai_authored` / `ai_tooling`),
  the exclusive `mentioned_only`, vendor, disclosure form, confidence and a
  one-sentence rationale, from the `ai_involvement_roles` seed definitions.
  Classify-once by content hash (text + model + `AI_PROMPT_VERSION`), cached in
  the committed `data/raw/{commit,thread}_ai_involvement.csv` (also the
  fresh-build fallback). A build classifies at most
  `var('ai_involvement_max_inline_classifications')` new texts inline and
  otherwise fails fast pointing at the resumable `pg-backfill-ai`
  (~2s/text; the full corpus is ~14h). **Cached-only mode is automatic, not
  configured:** every classify-once model (these two and
  `int_fix_content_categories`) probes Ollama at build time
  (`pg_analysis.sources.classify.ollama_unavailable_reason`: server reachable AND the tag
  installed); if not, it emits the cache and marks unseen texts
  `is_classified = false` with NULL labels -- the build succeeds with a WARN
  count, `fct_fixes.category` shows `'unclassified'`, and the CSV export skips
  those rows so the next Ollama build classifies exactly them. Never write an
  unclassified row to a cache CSV (it would be "cached" as unclassified forever).
  **The charts never read the model tables directly:** `int_commit_ai_labels` /
  `int_thread_ai_labels` apply the hand-review seed `ai_involvement_reviews`
  (every model positive + every rejected keyword hit was read by a person) on
  top of the model, and `dim_commit` / `fct_threads` carry those. The
  chart-facing flag is `has_ai_involvement` (a vendor AND a work role;
  `ai_mentioned_only` is a reference, not involvement); the roles are
  independent, so a role breakdown counts role-mentions, not fixes. A prompt
  change means a full re-scan: batch prompt fixes in TODO.md and bump once.
  Bumping `AI_PROMPT_VERSION` re-infers everything; tune the prompt against the
  hand-labeled set BEFORE a full scan. The regex `ai_credit` on
  `int_git_commits` is the legacy single-boolean signal (role-blind; vendor
  list only) and is superseded by these flags. The model cannot see undisclosed
  AI use: a rising line partly measures disclosure norms (PostgreSQL had no AI
  policy as of mid-2026), which is why `disclosure_form` is recorded.
- **Thread identity is transitive** (`int_message_threads`): parent = In-Reply-To
  else the last References id; root = the topmost archived ancestor, climbed
  with a recursive CTE per list. Never take "the first References id" as the
  root (clients send partial chains; it fragments threads). `is_thread_start`
  = no reply header (a genuinely new thread); `is_thread_root` = the earliest
  archived message of its thread (the grain of `fct_threads`, which is also
  where "bug reports" incl. free-form ones and thread outcomes live).
- **The OPEN release is defined by the registry, not the clock**
  (`int_releases`): the first scheduled release after the latest TAGGED one.
  Between a wrap Monday's tag and its Thursday the just-tagged release is
  already `shipped` with `is_announced = false`; keying "open" on today's date
  produced the same `release_dt` twice in that window. Every model that reads
  the clock goes through the `as_of_date()` macro (`var('as_of_date')`, null =
  `CURRENT_DATE`) so a dbt unit test can pin the day; never set the var for a
  real build.
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