# Working notes for AI assistants in this repo

`README.md` is the first-time user's introduction: the question, the
dashboards, the quickstart. This file is the reference behind it —
architecture, modelling decisions, conventions, operational gotchas and
forward-looking notes — things that would otherwise be lost between sessions.
(Use this file instead of per-session memories, which aren't committed to
git.) Open work lives in `TODO.md`.

**Document the current state, not its history.** These files (this one and
`README.md`) describe how the repo works *now* — not how it used to work, what
changed, or what was renamed, retired, or fixed in some version. When you change
something, rewrite the affected note to the new truth and delete the old
wording; don't append "was X, now Y", "used to", "no longer", "fixed in vN", or
before/after numbers. History lives in git; docs that narrate it only bloat.

## Commits
- **Never `git commit` or push without asking first and getting explicit
  confirmation.** Finish and verify the work (dbt build / tests / lint), leave
  it uncommitted, and propose a commit message — then wait.
- **Commit directly on `main`. Do NOT create feature branches** — the user works
  trunk-based here; don't branch before committing even though `main` is the
  default branch.
- Commit-message trailers this repo uses are set by the environment; keep them.

## Licensing
Dual-licensed by content type, copyright Dorian Insights, L.L.C.: code under
MIT (`LICENSE`), data under CC BY 4.0 (`LICENSE-DATA`). `REUSE.toml` is the
machine-readable declaration and the single place the split is defined:
`data/**` and `seeds/*.csv` are data, the article board is `MIT AND
CC-BY-4.0` (prose + queries), everything else is MIT. A new data directory or
prose-bearing file gets an annotation there, not a per-file SPDX header (the
`LICENSES/` copies of both texts are what `reuse lint` resolves against).
`pyproject.toml` declares the package license as the SPDX expression `MIT`
with `license-files = ["LICENSE"]`; `CITATION.cff` carries the citation and
must stay valid CFF 1.2.0. Neither the git clone nor the mbox archives are
distributed (gitignored `.cache/`), so no third-party notice is needed.

## Architecture

### Pipeline
Three fetch stages, then one dbt build, then the boards:

```
pg-cve-scrape ──> data/raw/cve_severity.csv ─┐
pg-clone ──> .cache/postgres.git ────────────┼─> dbt + DuckDB (the root) ──> transform.duckdb marts ──> charts/*.yml (dct)
             (full bare clone: commits,      │        │ (typed tables — what the boards read) (visualization)
              tags, AND release-notes SGML)  │        └────> data/derived/*.csv (diffable audit export)
pg-mail-sync ──> .cache/mbox/ ───────────────┘
             (monthly mbox archives)
             (all read directly at build time)
```

- **The dbt project root IS the repo root**: `dbt_project.yml`, `profiles.yml`
  (so no `~/.dbt` setup), `vars.yml`, `dbt_charts.yml`, `models/`, `seeds/`,
  `macros/`, `tests/`, `charts/` and the warehouse sit beside `python/` and
  `data/`, so every dbt, dct and DuckDB command runs from the root with no
  `cd`. Python 3.10-3.13 (3.14 not yet supported by dbt-charts).
- **`pg-refresh`** runs the three fetches in order, then `dbt deps` + `dbt
  build`; the build runs only if every fetch succeeded. `--list` shows the
  steps, `--only <step>` / `--skip <step>` select them, `--no-build` refreshes
  the sources only. Each fetch is independent and idempotent: past mbox months
  and the immutable git history are cached forever, so a refresh re-fetches
  only what changed. A first run cannot skip the mail step: the build reads
  the mbox cache. The mbox sync needs a free postgresql.org community account
  (`POSTGRES_COMM_USERNAME` / `POSTGRES_COMM_PASSWORD` in the gitignored
  `.env`).
- The release notes are parsed straight from the clone's SGML at build time
  (`pg_analysis.sources.sgml` -> `raw_release_items` / `raw_item_commits`) —
  no separate extraction step, no HTTP. An archived HTML scraper
  (`archive/scrape_release_notes.py`, from postgresql.org) parses the same
  notes and is kept only as a manual cross-check reference — not wired into
  the build, not maintained. One known divergence: nested remediation
  sub-bullets (e.g. CVE-2024-4317's three steps) fold into their parent item
  in SGML instead of counting as separate fixes — a correction.

### The Python package (`pg_analysis`)
- **The Python side is one editable-installed package, `pg_analysis`**
  (`python/pg_analysis/`: `corpus`, `paths`, the three fetchers,
  `refresh_data`, the two LLM backfills, `embed_fixes`, and `sources/` — the
  build-time readers the dbt Python models import: `git`, `sgml`, `mail`,
  `classify`, `ai_involvement`). `requirements.txt` (the one lockfile;
  `pyproject.toml` pins nothing) ends with `-e .`, so a fresh venv gets it
  from `pip install -r requirements.txt`; the `pg-*` console scripts
  (`pg-refresh`, `pg-clone`, `pg-mail-sync`, `pg-cve-scrape`,
  `pg-backfill-ai`, `pg-backfill-categories`, `pg-embed-fixes`) land in
  `venv/bin` from `[project.scripts]`. **Every import is an ordinary
  `from pg_analysis... import`** — the dbt models, the tests, the backfills:
  never add a `sys.path.insert` or a `Path(__file__)`/`Path.cwd()` anchor.
  **Every repo path comes from `pg_analysis.paths`** (`REPO_ROOT`, `CLONE`,
  `MBOX_CACHE`, `DATA_RAW`, `DBT_PROJECT_DIR`, `SEEDS_DIR`, `WAREHOUSE`,
  `ENV_FILE`); it locates the repo from its own file, which is why the install
  must stay editable (a non-editable install would resolve to site-packages
  and find nothing — the package is a working checkout's tool, not a
  distributable). Adding a runnable module = add its `main()` to
  `[project.scripts]`; the venv picks it up on the next `pip install -e .`.
  `refresh_data` calls the fetch modules' `main()` in-process (a step fails
  when `main()` raises; only dbt is a subprocess), so a fetch's failure
  signal must stay an exception or `SystemExit`, never a bare `return`
  after printing an error.
- **Beside the pipeline, not part of it:** `pg-backfill-ai` /
  `pg-backfill-categories` (the bulk LLM classifiers, see the AI-involvement
  design note) and `pg-embed-fixes`, a prototype that embeds each distinct
  fix's release-note text with Ollama's `nomic-embed-text` into a gitignored
  `.cache/fix_embeddings.parquet` for bottom-up clustering experiments — it
  reads the warehouse and is not wired into dbt.
- **The corpus is defined in `pg_analysis.corpus`** (`FIRST_MAJOR`; the upper
  bound is discovered from the clone) and shared by every reader so their
  datasets can never diverge. There is no history *date*: master is bounded
  by tag ancestry (`HISTORY_FLOOR_TAG..master`, the previous major's GA tag,
  i.e. exactly `FIRST_MAJOR`'s development onward -- the same rule as the
  stable branches' `REL_M_0..`), and the one consumer that needs a calendar
  day, the mailing-list sync, reads the branch point from the clone
  (`corpus.history_floor()`). Extending the analysis back in time is an edit
  there — a deliberate, versioned commit, not a flag or an env var
  (`FIRST_MAJOR >= 11`: the floor tag is the previous major's GA and PG 9.x
  tags are not `REL_M_N`-shaped).
- **The scrapers are pure extraction** — fields land raw verbatim. Every
  derivation lives in the transform: the AI-credit flag (`int_git_commits`),
  CVE extraction (`int_fix_items`), release-tag filtering and major/minor
  parsing (`stg_git_tags`), per-release item counts for the out-of-band rule
  (`int_releases`).

### Data files (`data/`)
Two subdirectories, one per pipeline direction; nothing writes and reads the
same directory.
- `data/raw/` holds what dbt sources read: the one external CSV
  `cve_severity.csv` (one row per published PostgreSQL CVE, from
  `pg-cve-scrape` off postgresql.org/support/security: CVSS v3 base score +
  vector + component; the NONE/LOW/MEDIUM/HIGH/CRITICAL band is derived
  downstream) and the three LLM label caches (`fix_content_categories.csv`,
  `commit_ai_involvement.csv`, `thread_ai_involvement.csv` — each both the
  fresh-build fallback and the committed export of its classify-once model).
- `data/derived/` holds the CSV **audit exports** of the mart tables, written
  by the transform's on-run-end hook — committed and line-diffable in review,
  but read back by nothing (the boards read the typed mart tables in
  `transform.duckdb`, so DATE/DOUBLE/BIGINT typing survives end to end with
  no re-casting). One `.csv` per mart, same name, only for marts under the
  size gate (see the design note on CSV twins).
- **Git-side and mail-side data have no CSV landing layer at all**: the clone
  at `.cache/postgres.git` is content-addressed and immutable — its own
  perfect raw store — so `models/raw_git/` reads it directly at build time
  and every git-derived table shares one consistent snapshot of the clone.
  Likewise the monthly mbox files at `.cache/mbox/` (immutable once a month
  is past) are decoded directly by `models/raw_mail/`. pgsql-hackers is in
  the sync beside pgsql-bugs so commit `Discussion:` trailers can be resolved
  to their source list (the origin-attribution models).

### Transform layers (`models/`)
Each layer lives in its own schema — `raw`, `staging`, `intermediate`,
`marts`, `seeds` (the `generate_schema_name` macro uses the configured names
verbatim instead of dbt's target-prefixed default), so browsing the .duckdb
shows the layer in every object's name. The marts are typed tables inside
`transform.duckdb` — the interface the boards query (dct's `warehouse` source
opens the file read-only) and what dbt tests run against. Two on-run-end
hooks: `macros/export_marts_csv.sql` writes the `data/derived/*.csv` twins,
and `macros/drop_orphaned_relations.sql` drops any table or view in a
dbt-managed schema that no model produces — the residue of a rename or
delete, which dbt never removes itself. `transform.duckdb` stays gitignored;
`dbt build` regenerates it.

- `models/raw_git/` — Python models (dbt-duckdb) that read
  `.cache/postgres.git` directly via `pg_analysis.sources.git` (and
  `pg_analysis.sources.sgml` for the notes): commits with full message bodies,
  per-commit `--numstat` file rows, every `REL_1x_*` ref, the release-notes
  items and their commit annotations, the commit → version map by exact tag
  ancestry (`raw_commit_versions`, one `rev-list` per tag, rebuilt in full),
  and the weekly per-branch tree-size snapshots (`raw_branch_size_weekly`,
  one `git grep -c` per branch HEAD — the one **incremental** model, since a
  past week's snapshot is immutable) — verbatim strings, one consistent clone
  snapshot per build. Requires the clone. The readers take the clone path and
  the corpus bounds from `pg_analysis.paths` / `pg_analysis.corpus`.
- `models/raw_mail/` — Python model decoding the `.cache/mbox/` archives
  via `pg_analysis.sources.mail`: per message, the bare headers (RFC 2047
  decoded), the Date header as an ISO string with its original offset,
  and the first text body part. Splitting is on the archive's own
  envelope line — stdlib `mailbox` oversplits on the `From <sha>` first
  line of attached git patches. Requires the cache.
- `models/staging/` — typed views over the raw CSVs and raw_git tables
  (`stg_*`; `stg_git_tags` carries both the `REL_M_N` release tags and the
  BETA/RC milestones that label the in-progress major's stage, told apart by
  `tag_kind`). The CSV source reader restricts type-sniffing to
  BIGINT/DATE/VARCHAR so version strings like "15.10" can't collapse into
  doubles.
- `models/intermediate/` — the analysis steps as tables: `int_releases`
  (release grain + flags), `int_fix_items` (fix items + dedup keys + derived
  CVEs), `int_fix_groups` (cross-branch dedup as recursive-CTE connected
  components), `int_fix_reps` (one categorized representative per distinct
  fix), `int_git_commits` (the commit spine's `fix_key` / `is_housekeeping` /
  AI-credit flags), `int_commit_versions` (the ONE commit → version/release
  mapping), `int_major_development` (per-major development activity,
  aggregated from it), `int_committed_fixes` (the committed-fix population:
  one row per distinct fix per release, linked to its release-notes item; the
  per-release rollup of both populations + documentation rate lives on
  `dim_release`), `int_commit_bug_links` (every commit -> bug-report link, by
  Discussion trailer or `Bug: #` mention -- read by `int_bug_reports` for the
  report's outcome and `bridge_fix_bug`), `int_commit_profile` (per-commit
  file/line counts, churn and the dominant-subsystem vote over
  `int_commit_files`, carried by `dim_commit` and read for a fix's
  representative commit by `int_fix_profile`, the per-fix rollup of its
  commits: coverage, change profile and origin), `int_message_threads` /
  `int_person_map` (thread and identity resolution, see the design notes),
  and the AI-involvement chain `int_*_ai_texts` -> `int_*_ai_involvement` ->
  `int_*_ai_labels` (see the AI-involvement design note).
- `models/marts/` — the typed tables the boards and CSV exports read: the
  fix-grain `fct_fixes`, the file-grain `fct_commit_files` churn fact (with
  its `dim_commit` spine), the release/projection/pace rollups, and the star
  below. Watch aggregate types here: DuckDB's `SUM(INTEGER)` is HUGEINT,
  which downstream writers silently turn into DOUBLE — cast count-like sums
  to `::BIGINT` at the aggregation site.
- `seeds/` — the classification data: `projection_methods` (the forecast
  recipes `fct_fix_projections` applies -- its method dimension, a seed
  lookup denormalized onto the fact), `content_categories` (the 13-category
  fix taxonomy + definitions; fixes are assigned to it by
  `int_fix_content_categories`), `ai_involvement_roles` (the disclosed-AI
  role definitions the `int_*_ai_involvement` prompts are built from),
  `ai_involvement_reviews` (the hand review of every text the model tied to
  an AI plus every rejected keyword hit, whose final labels override the
  model), `subsystem_rules` (path patterns; the directory area) and
  `file_class_rules` (extension -> file kind; the orthogonal what-kind-of-file
  taxonomy — both applied per file in `int_commit_files` and per weekly tree
  in `fct_branch_size_weekly`), and the range-bucket tables
  `cvss_severity_bands` (CVSS v3 base score -> NONE/LOW/MEDIUM/HIGH/CRITICAL,
  range-joined by `stg_cve_severity` per CVE; `fct_fixes` keeps the worst
  CVE's band per fix) and `latency_windows` / `thread_size_windows` (each
  range and its label defined together; the marts join them, and
  relationships tests replace duplicated label lists).

### The star schema (Kimball)
Alongside the analysis-shaped marts, a conformed star sits at the lowest
grains (key and special-member conventions are in the design notes below):
- **Dimensions:** `dim_person` (git authors + committers + list senders
  unified to one person), `dim_date` (keyed on `date_day`, a real DATE),
  `dim_release` (shipped releases + open/future cycles + the in-progress
  major's `.0`, status-flagged; the cycle signals ride on it too),
  `dim_version` (one grain below `dim_release`: one row per individual minor,
  e.g. `18.6`, conformed up to its release via `dim_release_key` — NULL for
  the `.0` majors that ship alone — and to its major via `dim_major_key`;
  its changelog `item_cnt` rides here), `dim_major` (the release line above a
  version: stable branch, support window), `dim_cve`, `dim_bug`, and
  `dim_commit` (one row per git commit — its attributes + conformed keys, no
  measures: `dominant_subsystem`, `branch_scope`, the AI-credit and origin
  flags, a `dim_version_key`).
- **Facts:** `fct_commit_files` (commit-file grain: line counts + subsystem +
  file_class, FK to `dim_commit`, conformed to `dim_date` — the atomic churn
  fact every churn metric rolls up from dynamically, at any time grain or
  slice, filtering generated file classes in or out), `fct_branch_size_weekly`
  (periodic snapshot: each stable branch's tree size per week by subsystem
  and file_class), `fct_messages` (message grain), `fct_threads` (thread
  grain: one row per mailing-list thread with its start, size and outcome --
  cited by a backpatched fix, beta stabilization, trunk work, or not), and
  `fct_fixes` (fix grain). A commit's measures are aggregates of its
  `fct_commit_files` rows, so there is no commit-grain fact; distinct-commit
  counts (non-additive) are `COUNT(DISTINCT ...)` over that grain in the
  boards' SQL, not a stored table. Mailing-list traffic has no materialized
  agg either: the boards roll it up from `fct_messages` at query time — the
  counts and the non-additive fix-linked share alike, at each chart's grain.
- **Bridges and aggregates:** the fix<->CVE, fix<->bug and fix<->contributor
  many-to-manys go through `bridge_fix_cve` / `bridge_fix_bug` /
  `bridge_fix_contributor` (the last parses the item's "(Name, Name)" credit
  list); `fct_release_categories_agg` and `fct_release_contributors_agg` are
  conformed aggregates of `fct_fixes` (+ the contributor bridge); the period
  aggregates (`fct_bug_reports_monthly_agg`, `fct_origin_activity_monthly_agg`)
  are conformed on `dim_date` by their month/week DATE. The single-open-release
  forecast is `fct_fix_projections` (grain release x method, replayed for
  every shipped release so the actual on `dim_release` scores it).
- Referential integrity is enforced by `relationships` tests on every FK
  (every mart's date columns join `dim_date` directly), and singular tests pin
  each fact's row count to its grain.

### Analysis parameters (`vars.yml`)
Every analysis parameter is a dbt var in `vars.yml` at the repo root (dbt >=
1.12 auto-parses it; the `vars:` block must live in that ONE file, not also
in `dbt_project.yml`), each with a comment saying what it controls: the
analysis knobs (`scheduled_release_min_items`, `pace_comparison_cycles`,
`wrap_tag_window_days`, `seasonality_window_days`), the `fct_fix_projections`
knobs (`reversion_baseline_releases`, `origin_projection_cycles`,
`projection_min_window_days`), the AI-involvement classifier's
`ai_involvement_text_cap_chars` / `ai_involvement_max_inline_classifications`,
the build's clock `as_of_date` (null = today; only dbt unit tests set it),
the CSV-export size gate `derived_csv_max_rows`, and the release schedule
(`release_months`, `release_calendar_horizon_months`, `major_support_years`).
Editing a parameter changes what the results mean — treat it like a corpus
change.

### Tests
- **dbt:** roughly 900 data tests (`dbt ls --resource-type test` for the
  exact count) plus one dbt unit test that pins `as_of_date` to replay the
  wrap-Monday-to-Thursday window: column-level schema tests (uniqueness,
  not-null, relationships, accepted ranges on counts and dates, regex format
  checks) using `dbt_utils` and Metaplane's `dbt_expectations` (installed via
  `dbt deps`), plus the singular reconciliation tests in `tests/` (rollups vs
  the item grain, commit annotations vs items, connected-components sanity,
  the release calendar vs observed wraps, and the forecast fact's target
  population and open-release completeness). `dbt build` is therefore also
  the validation pass.
- **Python:** unit tests for the package (`corpus`, `mailing_list_sync`,
  `scrape_cve_severity`, `postgres_clone`, `refresh_data` — its step
  selection and the in-process step runner's failure mapping) and its
  `sources` readers live in `python/tests/` — pure parse/logic coverage, no
  network, clone, or warehouse; they import the editable-installed package
  like everything else. `./venv/bin/pytest` (~0.1s). The DuckDB Python models
  (`models/raw_*`) are thin wrappers over the tested readers, so they carry
  no separate unit tests.

### Dashboards (`charts/`) and dbt charts
The visualization layer is [dbt charts](https://docs.dbtcharts.com/)
(**`dbt-charts` 0.8.0**, CLI **`dct`**, project config `dbt_charts.yml`
beside `dbt_project.yml`). Every face is plain SQL (no MetricFlow) against
the read-only `warehouse` DuckDB source. Rendered copies land in `out/`
(gitignored; regenerate with `dct render`). The boards:

- `1_fix_analysis.yml` (the leading `1_` orders it first in `dct serve`) —
  source attribution: documented fixes per release by origin (counts and
  share), committed fix commits per release by origin with the next
  release's so-far bar, and AI-flagged master commits by origin — the
  grounding for report-volume -> fix-volume projections.
- `changelog.yml` — the release-notes view: fixes per release by branch,
  category mix (absolute + 100%), out-of-band releases, the security hockey
  stick, contributors first-time-vs-returning, the next-release projection
  scenarios with their assumptions, and a table of every release.
- `git_activity.yml` — the commit-level view: quarterly distinct backpatched
  fixes, per-branch and per-version series, codebase size over time by major
  and its composition by subsystem (from `fct_branch_size_weekly`), lines
  churned / backpatch breadth / trunk churn by subsystem per quarter, fix
  commits disclosing AI involvement (chart, the per-quarter role breakdown,
  and the full table), the like-for-like release-cycle pace comparison, and
  commits by hour of day.
- `bug_reports.yml` — the pgsql-bugs view: monthly report volume with a
  6-month average, weekly volume with a 3-week average, acted-upon
  share, fix front-loading by release quarter (first 20 days vs the full
  cycle), outcome and latency breakdowns by year, discussion volume by
  outcome, and the most-discussed reports table.
- `projected_fixes.yml` — the forward-looking view of the next scheduled
  minor: live accrual counters since the last wrap, the signal estimates
  from `fct_fix_projections`, each estimator's ratio history, early vs
  final fixes per cycle, and a backtest + method scorecard over the shipped
  releases.
- `email_list_analysis.yml` — the mailing lists themselves: monthly and
  weekly traffic vs the fix-linked subset, the fix-linked share,
  new pgsql-hackers threads by what they led to (backpatched fix / beta
  stabilization / trunk work / not cited) with latency and cited-share KPIs,
  the discussion threads cited by master commits per month, and threads
  disclosing AI involvement (by role, by list, and the full table).
- `fix_impact.yml` — impact & severity: security fixes by CVSS band, fix
  size and backpatch breadth by severity, and time-to-fix vs change size —
  how a fix's size and severity relate to its timeline and reach.
- `article_llms_postgres.yml` — the write-up "AI, LLMs, and the Pace of
  Postgres Bug Fixing" as a board: the prose inline, every figure the live
  chart it was taken from on the other boards.

dct mechanics and quirks that shape the boards:

- Queries name models with `{{ ref('model') }}`, resolved through
  `target/manifest.json`, which also lets `dct validate charts/*.yml` check
  each query's columns statically against the compiled models — so run
  `dbt parse` after adding or renaming a model or column, and **keep every
  mart's outermost projection explicit** (see the coding conventions). Before
  renaming a mart column, run `dct impact <column>` to list the boards and
  queries that read it.
- Boards carry an informational `_schema_version` stamp written by
  `dct migrate`; never edit it by hand, and rerun `dct migrate charts/` after
  a dct upgrade. The dct workflow skills live in the gitignored
  `.claude/skills/dct-*/` (`dct init skills claude`; rerun after an upgrade --
  it overwrites the skills and removes any no longer shipped; no `-f` flag).
- **The query's ORDER BY orders a categorical axis** -- the simplest way to
  order one, and every board renders pixel-identical relying on it. An
  authored `sort:` orders a bar by the sort column's own value -- a stacked
  bar by its stacked total, a grouped bar by its SMALLEST series (sort by a
  pre-summed column when you want the group total). A single-series
  HORIZONTAL bar defaults to value-descending order (`projected_fixes`
  `estimates` keeps its `sort:` for that reason); a `support_table` on such a
  bar drops that default (dbt-charts issue #8), so keep a single-series
  horizontal bar's ranking in its axis labels, not a support_table. The
  list-traffic charts draw the partial current period as the last point of
  the main series (the subtitle says so).
- **Board-level `style.charts` cascades like inline** for `min_height` /
  `max_height` (= one height pin per board) and `bar: { stack: ... }` (only
  on boards where EVERY bar chart is stacked -- the four mixed boards keep
  `stack:` inline; the bar block does not reach area charts) and
  `bar.orientation` (hoist a board-wide orientation there and drop the
  per-chart `orientation:` where every bar shares it, as `1_fix_analysis` and
  `fix_impact` do; boards that MIX bar orientations keep it inline).
- **Share (100%-stacked) charts feed COUNTS through `stack: normalize` with
  no `axis_y` format:** the axis is labeled in percent anyway and the hover
  shows share, count and total; an authored percent axis format
  percent-formats the hover's raw count column ("2000%") and dct warns
  (WARN-NORMALIZE-PERCENT-FORMAT-READS-RAW-VALUE), so keep the no-format rule.
- **KPI `support:`** is a second line under the label (a column, a `format:`
  such as `percent_delta`, an optional static glyph/tone -- static, so no
  glyph or tone on a signed delta); avoid a hyphenated word in its label (dct
  rewrites "full-quarter" as "full- quarter", the item 4 family).
  **`support_table:`** (a per-x strip of extra columns on a bar/line/area
  chart) defaults to ABOVE the plot, touching the subtitle; use
  `style.support_table: { position: bottom }` to sit it under the axis (the
  gap auto-sizes to rotated x labels).
- No native trendlines: the `*_trend` queries compute least-squares fits in
  DuckDB SQL (`REGR_SLOPE`/`REGR_INTERCEPT`) and draw them as dashed line
  layers with explicit stroke colors.
- Layer labels are appended to the y-axis title; keep them short or a chart
  can collapse to a sliver.
- Multi-series `y: [a, b]` with `color:` draws one series per measure x
  category, named "<category> - <measure>"; the list-traffic charts use it
  instead of unpivoting in SQL.
- Hover emphasis dims the other marks and drops a guide line on every chart
  family by default; switch it off per board with
  `style.charts.hover_emphasis.visible: false`.

## Operational gotchas
- **DuckDB is single-writer.** `transform.duckdb` (at the repo root) may be held open by
  an interactive session (Harlequin, `duckdb` CLI); a `dbt build` (read-write)
  then fails with a lock error. Quit those before building. Harlequin should be
  opened read-only from its own venv (`~/.venvs/harlequin`, with `duckdb` pinned
  to the version that wrote the file — currently 1.5.5) and **from the repo
  root** (`harlequin -r transform.duckdb`) — see the cwd gotcha below.
  Do **not** kill the user's live Harlequin — ask them to quit it; only
  terminate a leftover process they've confirmed is closed. Note the sqlfluff
  lint uses the **dbt templater** (so package macros like
  `dbt_utils.generate_surrogate_key` expand) — it compiles the project per run, so a
  write-locked DuckDB breaks *linting* too, not just builds. `requirements.txt`
  pins `sqlfluff-templater-dbt` in lockstep with `sqlfluff`.
- A full `dbt build` re-reads the git clone + mbox cache each run. The mbox
  parse (`raw_list_messages` via `pg_analysis.sources.mail`) is the dominant cost and
  fans out across a process `Pool` (spawn — the parent is multithreaded, so fork
  is unsafe), ~43s; `raw_commit_files` (git side) is the
  next-slowest and serial. Use `dbt build --select <models>` while
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
- **Every check runs twice: per edit and at commit.** Repo-wide config in the
  root `pyproject.toml` (mirroring property_analysis): `ruff` (format + lint)
  and `pyright` (strict mode, all files; both point at `python/`); SQL style
  by `sqlfluff` (duckdb dialect + the dbt templater; config in the root
  `.sqlfluff`); the boards by `dct validate` (YAML schema + every query's
  columns against the compiled models); the package by `pytest`. The
  per-edit `.claude/hooks/` (`ruff-lint.sh`, `pyright-check.sh`,
  `sqlfluff-lint.sh`, `dct-validate.sh`, `pytest.sh` on any `.py` change)
  are **blocking** (exit 2 on a violation — fix it in the same turn, don't
  defer to commit); the `.pre-commit-config.yaml` gate (one-time setup:
  `./venv/bin/pre-commit install`) is the final backstop regardless of edit
  tool. Auto-fix layout nits with `./venv/bin/sqlfluff fix <file>`.
  Recurring sqlfluff snags: macOS `sed`/BSD `grep` have no `\b`; rule ST09 wants
  a join `ON` condition to lead with the earlier table (or an expression), not
  the joined table's bare column; RF02 wants every column qualified once a
  statement (incl. a scalar subquery) references more than one table; reserved
  words (`out`, `map`, `year`, `month`, `quarter`) can't be bare aliases/columns;
  `GROUP BY ALL` can't combine with `QUALIFY` (enumerate the columns there).
  **Lateral column aliases** (reusing a SELECT alias in a later expression,
  a `WHERE`, or a window's `PARTITION BY`) are used throughout, but a bare
  name that also exists as a column of any table in the FROM resolves to the
  COLUMN, not the alias -- silently when only one table has it, as an
  "ambiguous reference" error when two do. So never give a CTE output the
  same name as a final-select alias you mean to reuse (`fct_fix_origins_agg`
  names its CTE counts `documented_cnt` / `committed_cnt` for that reason),
  and an alias can't be used in a `JOIN ... ON` at all. A window over an
  aggregate alias (`COUNT(*) AS n, n / SUM(n) OVER ()`) works with an
  explicit `GROUP BY`.
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

## Coding conventions
- **No hardcoded dates or magic numbers** (other than `0` and `1`) in `.sql`
  or `.py`. Before writing a literal, **check `vars.yml`** for an
  existing variable and use `{{ var('...') }}` — analysis knobs
  (`scheduled_release_min_items`, `reversion_baseline_releases`, the `*_window_days`,
  the sentinel `past_eternity` / `future_eternity` dates, the release schedule
  `release_months` / `major_support_years`, etc.) all live there so a change
  means the same thing everywhere and is a reviewed edit. If the constant you
  need isn't a var yet, add it to `vars.yml` rather than inlining it. Calendar
  bounds are never literals at all: the release calendar, the `dim_date`
  spine and a major's EOL all derive from the corpus's tags
  (`macros/release_dates.sql`). The sentinel `1900-01-01` / `9999-01-01` are
  `var('past_eternity')` / `var('future_eternity')`; a "< N items" or "N days"
  threshold is almost always already a var.
- **SQL style** (enforced by sqlfluff where a rule exists; the naming ones
  are convention-only — sqlfluff has no column-naming rules):
  - Joins: always an explicit join type with `ON` conditions — `USING` is
    forbidden (sqlfluff ST07).
  - Booleans are real BOOLEANs (never 0/1 integers) and are named with an
    `is_`/`has_` prefix as grammatically appropriate (`is_acted_upon`,
    `has_test_changes`). Consumers write `WHERE is_x` / `WHERE NOT is_x`,
    and count them with `COUNT(*) FILTER (WHERE is_x)`, never `SUM(x)`.
  - Aggregate-derived columns carry the aggregate as a suffix: `*_cnt`
    (COUNT), `*_sum` (SUM), `*_median`, `*_avg`, `*_pct` — e.g.
    `report_cnt`, `lines_added_sum`, `days_to_commit_median`,
    `acted_upon_pct`. MIN/MAX keep semantic names (`first_commit_dt`,
    `last_message_dt`).
  - Timestamps keep full fidelity (ISO 8601 with offset) through raw and
    staging (`_ts` columns, TIMESTAMPTZ); truncation to a calendar day
    (`_dt`) happens as far downstream as possible, at the point of use, and
    buckets by UTC day.
  - No final `ORDER BY` in models — a table has no reliable order, so every
    consumer orders explicitly (the boards do; the CSV exporter uses
    `ORDER BY ALL` for deterministic committed files). `ORDER BY` inside a
    model is fine only where it is functional (with `LIMIT`, in window
    frames, in `STRING_AGG`).
  - `GROUP BY ALL` (DuckDB-native) instead of enumerating grouped columns —
    the one exception is a grouping column that `GROUP BY ALL` cannot see
    (referenced only inside an aggregate `FILTER`), which stays explicit
    with a comment.
  - Watch aggregate result types: DuckDB's `SUM(INTEGER)` is HUGEINT, which
    downstream writers silently turn into DOUBLE — cast count-like sums to
    `::BIGINT` at the aggregation site.
  - Marts end in an explicit column list, never `SELECT *` (why: the
    operational note on `dct validate`).
- **Python** passes pyright strict and the ruff rule set in `pyproject.toml`;
  new files must pass strict.

## Design decisions worth remembering
- **Identity resolution is connected-components.** `macros/person_node.sql`
  yields a per-(email,name) node key; `int_person_map` merges nodes that share a
  normalized email OR name (transitively, through the shared
  `connected_components` macro that `int_fix_groups` also uses) into one
  `person_key`. Facts compute the node key and JOIN `int_person_map`;
  `dim_person`, `dim_bug` reporters, and `dim_commit` authors all resolve
  through it. Real patch authors come from the commit body's `Author:` trailer,
  real bug reporters from the form body's `Logged by:` — not the git `%an` /
  From headers.
- **Cross-branch dedup is the same walk.** Two release-notes items in a
  release are the same fix when EITHER their normalized summary text
  (lowercased, whitespace collapsed, "§" markers stripped) OR their exact
  annotated commit-hash set matches, transitively (`int_fix_groups`, via the
  `connected_components` macro). `.0` feature releases are not fixes, and
  "update time zone data files" items are routine refreshes — both excluded.
- **Out-of-band releases** (emergency re-releases) are those whose largest
  release has fewer than `var('scheduled_release_min_items')` items; they are
  excluded from trend/pace series. The corpus's first shipped release
  accumulated only a partial cycle of fixes (with FIRST_MAJOR = 12 that is
  12.1, six weeks after 12.0) and is flagged `is_partial_window` on
  `dim_release` -- derived as the earliest shipped release, never named -- so
  projection fits and the trend charts exclude it.
- **Big marts have NO derived CSV twin** by design. `macros/export_marts_csv.sql`
  (on-run-end) writes a `data/derived/<mart>.csv` audit twin only for marts with
  fewer than `var('derived_csv_max_rows')` (1000) rows — a bigger table's diff is
  unreviewable and bloats the repo. So `fct_messages` (~160k), `fct_commit_files`
  (~100k), `fct_branch_size_weekly`, `dim_commit` (~23k), `dim_person`,
  `dim_date`, `dim_bug`, `fct_fixes`, `fct_threads` and
  `bridge_fix_contributor` have no CSV; query them in the warehouse, not
  `data/derived/`. The gate skips *writing* but can't *delete*,
  so if a mart grows past the threshold, `git rm` its now-stale CSV once.
- **Naming: dimensions singular, facts plural** is intentional (Kimball). Don't
  "fix" `fct_*` to singular.
- **Surrogate keys: every non-date dimension's PK is its first column, named
  `<table>_key`** (`dim_release_key`, `dim_version_key`, `dim_major_key`,
  `dim_bug_key`, `dim_cve_key`, `dim_person_key`), a
  `dbt_utils.generate_surrogate_key` hash (a uniform VARCHAR) computed ONCE,
  in the dimension. Facts/bridges get the FK by JOINing the dim on the natural
  key and selecting its `<table>_key` — never recompute the hash in the fact.
  Role-prefix where a fact references one dim twice (`author_dim_person_key` /
  `committer_dim_person_key`, `primary_dim_bug_key`, `ship_dim_release_key`).
  Dims keep the natural key as a plain attribute (`version`, `bug_number`,
  `cve_id`). `dim_person_key` is `int_person_map`'s connected-component id
  surfaced under the convention (NOT a fresh hash — that would break identity
  resolution). **`dim_date` is the deliberate exception:** no surrogate — facts
  store the DATE and join on `dim_date.date_day`.
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
  `future_eternity` (9999-01-01) rows (vars; `past_eternity_dt()` /
  `future_eternity_dt()` render the literals). Append the special rows with
  the `special_member_rows(key_column, columns, unknown, not_applicable)`
  macro (`macros/dim_special_members.sql`): the dim declares its projection
  once as a jinja `columns` list and passes only the non-NULL overrides. Never
  `UNION ALL BY NAME` (sqlfluff AM07 can't parse it). **Every dimension carries a `not_null` boolean `is_synthetic_row`**
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
  Stable-branch commit series count only post-`.0` commits (the backpatch
  stream); shared pre-branch history belongs to `master`. Security fixes are
  embargoed and reach public git only on wrap day, so mid-cycle security
  volume is structurally invisible.
  **Never SUM anything per stable-branch commit across branches** (churn, file
  counts): a fix is one commit per branch it was backpatched to, and the number
  of branches inside the corpus grew from one (2019) to every supported major
  (2023+), so the sum tracks the corpus, not the work. Sum over
  `dim_commit.is_representative_commit` (one backpatch per fix, its largest
  by churn) instead; the
  per-branch charts are comparable only from Q3 2023 on. `int_git_commits` defines `fix_key` (normalized subject —
  the identity of a fix across its backpatches) and `is_housekeeping` (stamps,
  translations, notes drafting, tz data: not fixes) once; every "distinct fix
  commits" count is `COUNT(DISTINCT fix_key) ... WHERE NOT is_housekeeping`
  (the boards read them off `dim_commit`). `int_committed_fixes` is the
  committed-fix population (grain release × fix_key) and `int_fix_reps` the
  documented one; `resolve_fix_origin` classifies both. Cycle-grain measures
  fold an out-of-band release into its cycle via
  `int_releases.cycle_ships_at_dt`; release-grain measures keep the exact
  release.
  A *documented* fix is a release-notes item (`fct_fixes`, via
  `int_fix_reps`): it exists only once the release ships and the notes author
  decides what gets an item. A *committed* fix exists the moment it lands and
  belongs to the release it ships in (tag ancestry) or to the open release
  (not yet tagged). The notes fold several commits into one item and document
  only ~40-60% of committed subjects (`dim_release.documentation_rate`), so
  the two counts are never equal; the notes' commit annotations link them
  (`is_documented`). The origins face keeps the two apart: "Fix origins per
  release" plots documented fixes for shipped releases, "Fix commits per
  release" plots committed fixes for every release including the open one's
  so-far bar, so each chart compares like with like (`fct_fix_origins_agg`
  carries both; the documented-units forecast of the open release is
  `fct_fix_projections`' origin_scaled method).
- **AI involvement is DISCLOSED involvement, read by a local LLM -- never a
  keyword filter.** `int_commit_ai_texts` (one text per `fix_key`) and
  `int_thread_ai_texts` (one per thread root) put EVERY commit and thread in
  scope (capped at `var('ai_involvement_text_cap_chars')`, NO keyword
  pre-filter); `int_commit_ai_involvement` / `int_thread_ai_involvement`
  (Python, `pg_analysis.sources.ai_involvement`) ask qwen3:30b-a3b for the
  four independent work-role flags (`ai_found` / `ai_analyzed` /
  `ai_authored` / `ai_tooling`), the exclusive `mentioned_only`, vendor,
  disclosure form, confidence and a one-sentence rationale, from the
  `ai_involvement_roles` seed definitions.
  Classify-once by content hash (text + model + `AI_PROMPT_VERSION`), cached in
  the committed `data/raw/{commit,thread}_ai_involvement.csv` (also the
  fresh-build fallback). A build classifies at most
  `var('ai_involvement_max_inline_classifications')` new texts inline and
  otherwise fails fast pointing at the resumable `pg-backfill-ai`
  (~2s/text; the full corpus is ~14h). The fix content taxonomy
  (`int_fix_content_categories`, cached in `data/raw/fix_content_categories.csv`,
  bulk job `pg-backfill-categories`) works the same way; both backfills refuse
  to start without Ollama and the model. **Cached-only mode is automatic, not
  configured:** every classify-once model (these two and
  `int_fix_content_categories`) probes Ollama at build time
  (`pg_analysis.sources.classify.ollama_unavailable_reason`: `OLLAMA_HOST`,
  default `http://localhost:11434`, reachable AND the tag `qwen3:30b-a3b`
  installed); if not, it emits the cache, marks unseen texts
  `is_classified = false` with NULL labels, prints the reason into the dbt
  log, and the build succeeds with a WARN whose count is the number of texts
  waiting. `fct_fixes.category` shows `'unclassified'` (the row is kept, so
  `fct_fixes` stays one row per fix; `fct_fixes.is_classified` says which),
  and the CSV export skips those rows so the next Ollama build classifies
  exactly them. Never write an unclassified row to a cache CSV (it would be
  "cached" as unclassified forever).
  **The charts never read the model tables directly:** `int_commit_ai_labels` /
  `int_thread_ai_labels` apply the hand-review seed `ai_involvement_reviews`
  (every model positive + every rejected keyword hit was read by a person) on
  top of the model, with `ai_label_source` = review / model / unclassified,
  and `dim_commit` / `fct_threads` carry those. The
  chart-facing flag is `has_ai_involvement` (a vendor AND a work role;
  `ai_mentioned_only` is a reference, not involvement); the roles are
  independent, so a role breakdown counts role-mentions, not fixes. A prompt
  change means a full re-scan: batch prompt fixes in TODO.md and bump once.
  Bumping `AI_PROMPT_VERSION` re-infers everything; tune the prompt against the
  hand-labeled set BEFORE a full scan. There is no keyword-regex AI signal. The
  model cannot see undisclosed AI use: a rising line partly measures
  disclosure norms (PostgreSQL had no AI policy as of mid-2026), which is why
  `disclosure_form` is recorded.
- **Thread identity is transitive** (`int_message_threads`): parent = In-Reply-To
  else the last References id; root = the topmost archived ancestor, climbed
  with a recursive CTE per list. Never take "the first References id" as the
  root (clients send partial chains; it fragments threads). `is_thread_start`
  = no reply header (a genuinely new thread); `is_thread_root` = the earliest
  archived message of its thread (the grain of `fct_threads`, which is also
  where "bug reports" incl. free-form ones and thread outcomes live). A *bug
  report* is a new pgsql-bugs thread (`fct_threads.is_new_thread`), form or
  free-form; the BUG # form reports alone (`dim_bug`) are about two thirds of
  them.
- **Reports link to fixes exactly, not fuzzily**: commit messages carry
  `Discussion: https://postgr.es/m/<message-id>` trailers (and sometimes
  `Bug: #NNNNN`), extracted by `int_commit_discussions` /
  `int_commit_bug_links` from the bodies already in `raw`. A pgsql-bugs
  report counts as acted upon when any message of its thread is cited by
  a commit, or the bug number is mentioned.
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
  `int_release_cycles`) are **folded onto the same row** — a cycle is a release
  earlier in its life, so its signals ride on this dimension rather than a
  separate fact; they're non-NULL only for the started scheduled cycles
  (`cycle_start_dt IS NOT NULL`).
  `fct_fixes.dim_release_key` conforms to `dim_release.dim_release_key`.
  `dim_release.release_dt` is the release day — the changelog aliases it back to
  `release_dt` for its charts.
