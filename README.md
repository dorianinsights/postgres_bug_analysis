# PostgreSQL patch analysis

Is Postgres fixing more, faster — and is LLM-assisted bug discovery behind it?
This pipeline uses the Postgres publicly available git repo and two of the mostly heavily used Postgres mailing lists - pgsql-bugs and pgsql-hackers as data sources to answer this question. It also separately obtains Postgres CVE ratings to provide some auxiliary vulnerability information.

## Basic Architecture

Once the data sources are available, the project uses dbt and DuckDB to do a series of transformations and calculations, provides a `marts` output layer, and renders
the analysis as [dbt charts](https://docs.dbtcharts.com/) dashboards.

Three explicit stages, each re-runnable on its own:

```
pg-cve-scrape ──> data/raw/cve_severity.csv ─┐
pg-clone ──> .cache/postgres.git ────────────┼─> dbt + DuckDB (the root) ──> transform.duckdb marts ──> charts/*.yml (dct)
             (full bare clone: commits,      │        │ (typed tables — what the boards read) (visualization)
              tags, AND release-notes SGML)  │        └────> data/derived/*.csv (diffable audit export)
pg-mail-sync ──> .cache/mbox/ ───────────────┘
             (monthly mbox archives)
             (all read directly at build time)
```

The Python side is one package, **`pg_analysis`** (`python/pg_analysis/`,
installed editable into the venv by `requirements.txt`): the corpus
definition (`corpus`), the three fetchers, the orchestrator (`refresh_data`),
the bulk LLM backfills, an embedding prototype, and `sources/`, the
build-time readers the dbt Python models import. Every path the package
touches (the caches, `data/raw/`, the dbt seeds, the warehouse, `.env`) comes
from one module, `pg_analysis.paths`, which locates the repo from its own
file, so nothing depends on the cwd and there is no `sys.path` juggling
anywhere — the dbt models, the tests and the scripts all write plain
`from pg_analysis... import` lines. The editable install also puts console
scripts in `venv/bin`: `pg-refresh` (the three fetches in order, then the
build — the Quickstart's step 2; it calls the fetch modules' `main()`
in-process and runs only dbt, a CLI, as a child process), `pg-clone`,
`pg-mail-sync`, `pg-cve-scrape`, and, beside the pipeline rather than part
of it, `pg-backfill-ai` / `pg-backfill-categories` (the bulk LLM classifiers,
see the Ollama section) and `pg-embed-fixes`, a prototype that embeds each
distinct fix's release-note text with Ollama's `nomic-embed-text` into a
gitignored `.cache/fix_embeddings.parquet` for bottom-up clustering
experiments — it reads the warehouse and is not wired into dbt. The package
is a working checkout's tool, not a distributable: a non-editable install
would find no repo around it.

## Quickstart

```bash
# 1. One-time setup (venv lives at the repo root; Python 3.10-3.13 — 3.14 not
#    yet supported by dbt-charts). requirements.txt pins every dependency AND
#    installs the repo's own pg_analysis package editable (`-e .`), which is
#    what puts the pg-* commands below in venv/bin. The mbox sync needs a
#    free postgresql.org community account: put POSTGRES_COMM_USERNAME /
#    POSTGRES_COMM_PASSWORD in .env (gitignored) before the next step.
python3.12 -m venv venv
./venv/bin/pip install -r requirements.txt

# 2. Fetch the sources and build the marts, in one command: the postgres
#    clone (first run: full bare clone, ~800MB), the pgsql-bugs +
#    pgsql-hackers mbox archives (full bodies; hackers is ~3GB on first
#    sync), the CVSS severity scrape (one small fetch), then `dbt deps` +
#    `dbt build` at the repo root — the build runs only if every fetch
#    succeeded. Same command for every later refresh: past mbox months and
#    the immutable git history are cached forever, so only what changed is
#    re-fetched. profiles.yml sits at the repo root, so no ~/.dbt setup.
./venv/bin/pg-refresh

# 3. Visualize: the dashboards, live in the browser (dbt_charts.yml sits
#    beside dbt_project.yml at the repo root)
./venv/bin/dct serve
```

Running a stage on its own — each fetch script is independent and
idempotent, the build is a plain dbt project, and the boards are plain YAML:

```bash
./venv/bin/pg-refresh --list          # the steps, in run order
./venv/bin/pg-refresh --only cve      # one fetch, then the build
./venv/bin/pg-refresh --skip mail     # everything but the slow mbox sync (needs an existing .cache/mbox/)
./venv/bin/pg-refresh --no-build      # refresh the sources without rebuilding
./venv/bin/pg-clone                   # or run one fetch on its own: pg-clone / pg-mail-sync / pg-cve-scrape
./venv/bin/dbt build                  # just the transform (dbt build --select <models> while iterating)
./venv/bin/dct validate charts/*.yml   # check the boards after editing one (the per-edit hook and pre-commit gate run this too)
./venv/bin/dct render charts/*.yml --format html --output "out/{stem}.html"   # export static HTML to out/ (gitignored)
```

The release notes are parsed straight from the clone's SGML at build time —
no separate extraction step, no HTTP. A first run cannot skip the mail
step: the build reads the mbox cache.

## Optional dependency: Ollama (the local LLM)

Three models are **classify-once** LLM classifiers that run a local model
through [Ollama](https://ollama.com): `int_fix_content_categories` (the fix
content taxonomy), and `int_commit_ai_involvement` / `int_thread_ai_involvement`
(disclosed AI involvement per committed fix and per mailing-list thread). Each
keeps its labels in a committed CSV under `data/raw/`, keyed by a content hash
of the text, so **a clone with current CSVs needs no Ollama at all**: every
text is already labeled and the build reads the cache. Ollama is only needed
for texts the cache has never seen -- new commits, threads and release-notes
items that arrive after the CSVs were last committed.

**Without Ollama, or without the model tag (`qwen3:30b-a3b`)**, nothing is configured and nothing fails: at
build time each classifier probes `OLLAMA_HOST` (default
`http://localhost:11434`) and, if the server is unreachable or the tag is not
installed, switches to **cached-only mode** -- it emits the cached labels, gives
every unseen text `is_classified = false` with NULL labels, prints the reason
into the dbt log, and the build **succeeds with a WARN** whose count is the
number of texts waiting. In the marts an unclassified fix shows its `category`
as `'unclassified'` (the row is kept, so `fct_fixes` stays one row per fix) and
`fct_fixes.is_classified` says which. Nothing unclassified is ever written to
the CSVs, so the next build with Ollama available classifies exactly those
texts and the WARN clears.

To classify locally: install Ollama, `ollama pull qwen3:30b-a3b`, and rebuild --
a build classifies up to `var('ai_involvement_max_inline_classifications')`
new texts inline (~2 s each); more than that (a prompt-version bump, a new
major, a fresh scan) is a bulk job for the resumable
`backfill_ai_involvement.py` / `backfill_classifications.py`, which refuse to
start without Ollama and the model.

## Data files (`data/`)

Two subdirectories, one per pipeline direction: `data/raw/` holds the
external CSV (`cve_severity.csv`) and the three LLM-inferred label caches
(`fix_content_categories.csv`, `commit_ai_involvement.csv`,
`thread_ai_involvement.csv` — each both the fresh-build fallback and the
committed export of its classify-once model) read by dbt sources; `data/derived/` holds the
CSV **audit exports** of the mart tables — committed and line-diffable in
review, but read back by nothing (the boards read the typed mart tables in
`transform.duckdb` at the repo root instead, so DATE/DOUBLE/BIGINT typing survives
end to end with no re-casting). Nothing writes and reads the same directory. **Git-side and mail-side data have no CSV landing layer at all**:
the clone at `.cache/postgres.git` is content-addressed and immutable — its
own perfect raw store — so the transform's `models/raw_git/` Python models
(commits, tags, the commit → version tag-ancestry map, the weekly tree-size
snapshots, AND the release-notes SGML, via `pg_analysis.sources.git` / `.sgml`)
read it directly at build time, and every git-derived table shares one
consistent snapshot of the clone. Likewise the monthly mbox files at
`.cache/mbox/` (immutable once a month is past) are decoded directly by
`models/raw_mail/`. The pgsql-hackers list joined pgsql-bugs
in the sync so commit Discussion: trailers can be resolved to their
source list (the origin-attribution models).

Raw (`data/raw/`, the one external CSV — rerun `pg-cve-scrape` to refresh):

| File | Grain | Source |
|---|---|---|
| `cve_severity.csv` | one published PostgreSQL CVE | `scrape_cve_severity.py` from postgresql.org/support/security: CVSS v3 base score + vector + component (the NONE/LOW/MEDIUM/HIGH/CRITICAL band is derived downstream) |

Derived (`data/derived/`, the CSV audit exports of the mart tables, written
by the transform's on-run-end hook — rerun `dbt build` to change analysis
rules without re-scraping; one `.csv` per mart, same name). Only marts under
`var('derived_csv_max_rows')` (1000) rows get a twin — the heavier ones
(`fct_messages`, `fct_commit_files`, `fct_branch_size_weekly`, `dim_commit`,
`dim_person`, `dim_date`, `dim_bug`, `fct_fixes`, `fct_threads`,
`bridge_fix_contributor`) live only as typed tables in the warehouse:

## Dashboards (`charts/`)

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

Rendered copies land in `out/` (gitignored; regenerate with `dct render`).

## Transform (the dbt project)

A dbt project targeting DuckDB (dbt-duckdb) whose project root IS the repo
root: `dbt_project.yml`, `models/`, `seeds/`, `macros/`, `tests/`, `charts/`
and the warehouse sit beside `python/` and `data/`, so every dbt, dct and
DuckDB command runs from the repo root with no `cd`. The raw CSVs are read in place as external sources, and the
marts are typed tables inside `transform.duckdb` — the interface the boards
query (dct's `warehouse` source opens the file read-only) and what dbt tests
run against, so types survive with no sniffing or re-casting. An on-run-end
hook (`macros/export_marts_csv.sql`) then exports every mart under the size
gate to its `data/derived/*.csv` twin for git-diffable review, and a second
one (`macros/drop_orphaned_relations.sql`) drops any table or view in a
dbt-managed schema that no model produces any more — the residue of renamed
or deleted models, which dbt never removes itself. `transform.duckdb` itself
stays gitignored — `dbt build` regenerates it — but note DuckDB is
single-writer: close interactive `duckdb` CLI sessions on it before
building. Each layer lives in
its own schema — `raw`, `staging`, `intermediate`, `marts`, `seeds` (the
`generate_schema_name` macro uses the configured names verbatim instead of
dbt's target-prefixed default), so browsing the .duckdb shows the layer in
every object's name. Layers:

- `models/raw_git/` — Python models (dbt-duckdb) that read
  `.cache/postgres.git` directly via `pg_analysis.sources.git` (and
  `pg_analysis.sources.sgml` for the notes): commits with full message bodies,
  per-commit `--numstat` file rows, every `REL_1x_*` ref, the release-notes
  items and their commit annotations, the commit → version map by exact tag
  ancestry (`raw_commit_versions`, one `rev-list` per tag, rebuilt in full),
  and the weekly per-branch tree-size snapshots (`raw_branch_size_weekly`,
  one `git grep -c` per branch HEAD — the one **incremental** model, since a
  past week's snapshot is immutable) — verbatim strings, one consistent clone
  snapshot per build. Requires the clone (run `pg-clone` or `pg-refresh`
  first). The models import the readers from the installed package like any
  other dependency; the readers take the clone path and the corpus bounds
  from `pg_analysis.paths` / `pg_analysis.corpus`.
- `models/raw_mail/` — Python model decoding the `.cache/mbox/` archives
  via `pg_analysis.sources.mail`: per message, the bare headers (RFC 2047
  decoded), the Date header as an ISO string with its original offset,
  and the first text body part. Splitting is on the archive's own
  envelope line — stdlib `mailbox` oversplits on the `From <sha>` first
  line of attached git patches. Requires the cache (run `pg-mail-sync`
  first).
- `models/staging/` — typed views over the raw CSVs and raw_git tables
  (`stg_*`; `stg_git_tags` carries both the `REL_M_N` release tags and the
  BETA/RC milestones that label the in-progress major's stage, told apart by
  `tag_kind`). The CSV source reader restricts
  type-sniffing to BIGINT/DATE/VARCHAR so version strings like "15.10" can't
  collapse into doubles.
- `models/intermediate/` — the analysis steps as tables: `int_releases` (release
  grain + flags), `int_fix_items` (fix items + dedup keys + derived CVEs),
  `int_fix_groups` (cross-branch dedup as recursive-CTE connected
  components), `int_fix_reps` (one categorized representative per distinct
  fix), `int_git_commits` (the commit spine's `fix_key` / `is_housekeeping` /
  AI-credit flags), `int_commit_versions` (the ONE commit → version/release
  mapping, trunk included: tag ancestry gives a shipped minor or a major's `.0`
  development, plus the open release for a released major's not-yet-tagged
  stable commits), `int_major_development` (per-major development activity,
  aggregated from it), `int_committed_fixes` (the committed-fix population: one
  row per distinct fix per release, linked to its release-notes item; the
  per-release rollup of both populations + documentation rate lives on
  `dim_release`), `int_commit_bug_links` (every commit -> bug-report link, by
  Discussion trailer or `Bug: #` mention -- read by `int_bug_reports` for the
  report's outcome, `int_fix_bug_links` and `int_commit_origins`),
  `int_commit_profile` (per-commit file/line counts, churn and the
  dominant-subsystem vote over `int_commit_files`, carried by `dim_commit` and
  read for a fix's representative commit by `int_fix_profile`, the per-fix
  rollup of its commits: coverage, change profile and origin),
  `int_commit_ai_texts` / `int_thread_ai_texts` (the text the AI-involvement
  classifier reads: one per committed fix, one per thread root, capped at
  `var('ai_involvement_text_cap_chars')`, NO keyword pre-filter) and
  `int_commit_ai_involvement` / `int_thread_ai_involvement` (the local-LLM
  labels: the four work-role flags `ai_found` / `ai_analyzed` / `ai_authored` /
  `ai_tooling`, the exclusive `mentioned_only`, vendor, disclosure form,
  confidence, rationale — classify-once by content hash, cached in
  `data/raw/*_ai_involvement.csv`, bulk-populated by
  `backfill_ai_involvement.py`; a build classifies at most
  `var('ai_involvement_max_inline_classifications')` new texts inline), and
  `int_commit_ai_labels` / `int_thread_ai_labels` (the FINAL labels: the model
  overridden by the hand review seed `ai_involvement_reviews`, with
  `has_ai_involvement` = a vendor AND a work role, and `ai_label_source` =
  review / model / unclassified -- what `dim_commit` and `fct_threads` carry).
- `models/marts/` — the typed tables the boards and CSV exports read: the
  fix-grain `fct_fixes` fact, the file-grain `fct_commit_files` churn fact
  (with its `dim_commit` spine), the release/projection/pace rollups, and the
  star (dims + facts) described below. Watch aggregate types here: DuckDB's `SUM(INTEGER)` is HUGEINT,
  which downstream writers silently turn into DOUBLE — cast count-like
  sums to `::BIGINT` at the aggregation site.
  - **Star schema (Kimball).** Alongside those analysis-shaped marts, a
    conformed star sits at the lowest grains: the dimensions `dim_person` (git
    authors + committers + list senders unified to one person, keyed by the
    shared `person_node()` macro + `int_person_map` connected-component
    resolution so several emails collapse to one person), `dim_date`,
    `dim_release` (shipped releases + open/future cycles + the in-progress
    major's `.0`, status-flagged), `dim_major` (the release line above a
    version: stable branch, support window), `dim_cve`, `dim_bug`, and
    `dim_commit` (one row per git commit — its attributes + conformed keys, no
    measures), with the facts `fct_commit_files` (commit-file grain: churn),
    `fct_branch_size_weekly` (periodic snapshot: each stable branch's tree
    size per week by subsystem and file_class), `fct_messages` (message
    grain), `fct_threads` (thread grain: one row per mailing-list thread with
    its start, size and outcome -- cited by a backpatched fix, beta
    stabilization, trunk work, or not), and `fct_fixes` (fix grain). A commit's
    measures are aggregates of its `fct_commit_files` rows, so the commit-grain
    fact was retired into `dim_commit` + the atomic file fact; distinct-commit
    counts (non-additive) are `COUNT(DISTINCT ...)` over that grain in the
    boards' SQL, not a stored table. `dim_version` sits one grain below `dim_release`:
    one row per individual minor (e.g. `18.6`), conformed up to its release via
    `dim_release_key` (NULL for the `.0` majors that ship alone) and to its
    major via `dim_major_key`; `fct_fixes` and `dim_commit` carry a
    `dim_version_key` FK to it (its changelog `item_cnt` absorbed the retired
    one-measure `fct_version_items_agg`).
    **Key convention:** every non-date dimension's PK is its first column, named
    `<table>_key` (`dim_release_key`, `dim_version_key`, `dim_major_key`,
    `dim_bug_key`, `dim_cve_key`, `dim_person_key`) and generated by
    `dbt_utils.generate_surrogate_key` (a uniform VARCHAR hash); facts link back
    with a matching `<table>_key`, role-prefixed where a fact plays the same
    dimension twice (`author_dim_person_key` / `committer_dim_person_key`,
    `primary_dim_bug_key`, `ship_dim_release_key`). `dim_date` is the deliberate
    exception — see below. The cycle grain is not a
    separate fact: a cycle is a release earlier in its life, so its signals ride
    on `dim_release`. The
    fix<->CVE, fix<->bug, and fix<->contributor many-to-manys go through
    `bridge_fix_cve` / `bridge_fix_bug` / `bridge_fix_contributor` (the last
    parses the item's "(Name, Name)" credit list); `fct_release_categories_agg` and `fct_release_contributors_agg`
    are conformed aggregates of `fct_fixes` (+ the contributor bridge). The period aggregates (`fct_bug_reports_monthly_agg`,
    `fct_origin_activity_monthly_agg`) are aggregate facts rolled up from those
    grains and conformed on `dim_date` by their month/week DATE. `dim_commit`
    carries a `dominant_subsystem` (`int_commit_profile`'s weighted vote over
    the per-file `int_commit_files`, which classifies each changed file by
    subsystem and by extension `file_class`), plus `branch_scope` (trunk/stable/beta) and
    the AI-credit and origin flags. The atomic churn fact **`fct_commit_files`** (one
    row per file per commit — line counts + subsystem + file_class, FK to
    `dim_commit`, conformed to `dim_date`) is where every churn metric rolls up
    from dynamically rather than from a frozen by-quarter table: the line-count
    charts aggregate the atomic fact on the fly (any time grain, any commit/file
    slice) and filter generated file classes (translation catalogs, test
    fixtures) in or out. (Mailing-list traffic has no materialized agg either:
    the `charts/` boards roll it up from the atomic `fct_messages` at
    query time — the counts and the non-additive fix-linked share alike, each
    computed at the chart's own grain.) `dim_date` is keyed on `date_day` (a real DATE) — there is
    no separate integer date surrogate; every mart's date columns join to it
    directly, and a `relationships` test on each one enforces the conformance.
    Following Kimball, no fact FK is ever NULL: every non-date dimension carries
    an **Unknown** and a **Not Applicable** member (surrogate keys from
    `generate_surrogate_key('-1')` / `'-2'`), and a LEFT-JOINed FK is COALESCEd
    to one of them — mandatory keys to Unknown (guarded by a `not_unknown_member`
    test), legitimately-absent optional keys to Not Applicable. `dim_date`'s
    equivalents are its real `past_eternity` / `future_eternity` rows.
    Referential integrity is enforced by `relationships` tests on every FK, and
    singular tests pin each fact's row count to its grain. Several older marts were superseded as the star grew —
    `fct_fixes` replaced `fix_impact` and `fix_items`; the cycle signals
    (`git_cycle_pace`, `fix_projection_cycles`, `int_cycle_signals`) were unified
    as `fct_release_cycles` and then folded into `dim_release` (`int_release_cycles`);
    `int_backpatch_fixes` / `int_pending_fixes` / `fct_pending_fix_origins_agg`
    (calendar-windowed commit counts) were retired into `int_committed_fixes` +
    `fct_fix_origins_agg` once every commit resolved to its release; the
    single-open-release forecasts `projections` (series scenarios) and
    `fix_projection_estimates` (signal estimators), plus
    `fct_fix_origins_agg`'s per-origin projection, were merged into the
    forecast fact `fct_fix_projections` (grain release x method, replayed
    for every shipped release so the actual on `dim_release` scores it).
- `seeds/` — the classification data: `projection_methods` (the forecast
  recipes `fct_fix_projections` applies -- its method dimension, a seed lookup
  denormalized onto the fact),
  `content_categories` (the 13-category
  fix taxonomy + definitions; fixes are assigned to it by int_fix_content_categories,
  which replaced the retired `category_rules` regex classifier),
  `ai_involvement_roles` (the disclosed-AI role definitions the
  `int_*_ai_involvement` prompts are built from), `ai_involvement_reviews`
  (the hand review of every text the model tied to an AI plus every rejected
  keyword hit -- 182 rows -- whose final labels override the model),
  `subsystem_rules` (path patterns; the directory area) and `file_class_rules`
  (extension -> file kind; the orthogonal what-kind-of-file taxonomy — both
  applied per file in `int_commit_files` and per weekly tree in
  `fct_branch_size_weekly`), and the range-bucket tables
  `cvss_severity_bands` (CVSS v3 base score -> NONE/LOW/MEDIUM/HIGH/CRITICAL,
  range-joined by `stg_cve_severity` per CVE; `fct_fixes` keeps the worst CVE's band per fix)
  and `latency_windows` / `thread_size_windows` (each range and its label
  defined together; the marts join them, and relationships tests replace
  duplicated label lists).

Analysis parameters live as dbt vars in `vars.yml` at the repo root (dbt >= 1.12
auto-parses it; the `vars:` block must live in that ONE file, not also in
`dbt_project.yml`), each with a comment saying what it controls: the analysis
knobs (`scheduled_release_min_items`, `pace_comparison_cycles`,
`wrap_tag_window_days`, `seasonality_window_days`), the `fct_fix_projections`
knobs (`reversion_baseline_releases`, `origin_projection_cycles`,
`projection_min_window_days`), the AI-involvement classifier's
`ai_involvement_text_cap_chars` / `ai_involvement_max_inline_classifications`,
the build's clock `as_of_date` (null = today; only dbt unit tests set it),
the CSV-export size gate `derived_csv_max_rows`, the `dim_date` spine bounds
(`date_spine_start` / `date_spine_end`), and the shared loose sanity floors the
range tests use (`test_floor_major`, `test_floor_release_dt`,
`test_floor_git_ts` — deliberately NOT the corpus bounds; `corpus.py` owns
those). No literal thresholds or dates appear in the models: a new constant
is a new var. Editing a parameter changes what the results mean — treat it
like a corpus change.

Every model is heavily tested — roughly 900 data tests in all (`dbt ls
--resource-type test` for the exact count; 891 as of 2026-09-10, plus one dbt
unit test that pins `as_of_date` to replay the wrap-Monday-to-Thursday
window): column-level schema tests
(uniqueness, not-null, relationships, accepted ranges on counts and dates,
regex format checks) using `dbt_utils` and Metaplane's `dbt_expectations`
(installed via `dbt deps`), plus the singular reconciliation tests in
`tests/` (rollups vs the item grain, commit annotations vs items,
connected-components sanity, the release calendar vs observed wraps, and the
forecast fact's target population and open-release completeness). `dbt build`
is therefore also the validation pass.

SQL conventions (enforced by sqlfluff where a rule exists; the naming ones
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

This project replaced `build_datasets.py` + `categorize.py` on 2026-08-28;
at cutover every derived CSV was verified field-identical against the
Python implementation's output (the only byte difference: the csv module
wrote CRLF line endings, DuckDB writes LF).

## Linting, type checking & tests

Repo-wide (config in the repo-root `pyproject.toml`, mirroring
property_analysis): `ruff` (format + lint) and `pyright` (strict mode, all files).
SQL style for the dbt models is linted by `sqlfluff` (duckdb dialect + the
**dbt templater**, so package macros like `dbt_date.get_base_dates` expand to
real SQL during lint — it compiles the dbt project per run, which
needs the DuckDB file unlocked, same as a build; config in the repo-root
`.sqlfluff`); correctness of the models is
covered by the dbt tests themselves; and the boards under `charts/`
are validated by `dct validate` (YAML schema + every query's columns against
the compiled models). All four are enforced twice — per-edit via
`.claude/hooks/` (`ruff-lint.sh`, `pyright-check.sh`, `sqlfluff-lint.sh`,
`dct-validate.sh`, all blocking) and at commit time by the blocking
pre-commit gate (`.pre-commit-config.yaml`; one-time setup:
`./venv/bin/pre-commit install`). A `PreToolUse` guard
(`bash-source-edit-guard.sh`) blocks shell writes to `.sql` / `.py` so an
edit can't slip past the per-edit hooks. Auto-fix layout nits with
`./venv/bin/sqlfluff fix <file>`.

Python **unit tests** for the `pg_analysis` package (`corpus`,
`mailing_list_sync`, `scrape_cve_severity`, `postgres_clone`,
`refresh_data` — its step selection and the in-process step runner's
failure mapping) and its `sources` readers (git, sgml, mail, classify,
ai_involvement) live in `tests/` — pure parse/logic coverage, no network,
clone, or warehouse. They import the editable-installed package exactly as
the dbt models and console scripts do, so no path configuration is needed
(pyright and ruff point at `python/` in `pyproject.toml`). Run them with `./venv/bin/pytest` (~0.1s). They're
enforced the same two ways: a per-edit `pytest.sh` hook on any `.py` change and
the `pytest` hook in the pre-commit gate. The DuckDB Python models
(`models/raw_*`) are thin wrappers over the tested readers, so they
carry no separate unit tests.

## Analysis conventions

- **The corpus is defined in `pg_analysis.corpus`** (`python/pg_analysis/corpus.py`; (`FIRST_MAJOR`; the upper bound is
  discovered from the clone) and shared by every reader so their datasets can
  never diverge. There is no history *date*: master is bounded by tag ancestry
  (`HISTORY_FLOOR_TAG..master`, the previous major's GA tag, i.e. exactly
  `FIRST_MAJOR`'s development onward -- the same rule as the stable branches'
  `REL_M_0..`), and the one consumer that needs a calendar day, the mailing-list
  sync, reads the branch point from the clone (`corpus.history_floor()`).
  Extending the analysis back in time is an edit there — a deliberate,
  versioned commit, not a flag or an env var (`FIRST_MAJOR >= 11`: the floor
  tag is the previous major's GA and PG 9.x tags are not `REL_M_N`-shaped).
- `.0` feature releases are not fixes; "update time zone data files" items are
  routine refreshes — both excluded.
- A release is **out-of-band** (emergency re-release) when its largest release has
  fewer than 20 items; out-of-band releases are excluded from trend/pace series.
- Cross-branch dedup: two items in a release are the same fix when EITHER their
  normalized summary text (lowercased, whitespace collapsed, "§" markers
  stripped) OR their exact annotated commit-hash set matches, transitively
  (connected components via the `connected_components` macro in
  `int_fix_groups.sql`, the same walk `int_person_map` uses for identity
  resolution).
- The corpus's first shipped release accumulated only a partial cycle of fixes
  (with FIRST_MAJOR = 14 that is 14.1, Nov 2021, six weeks after 14.0) and is
  flagged `is_partial_window` on `dim_release` -- derived as the earliest shipped
  release, never named -- so projection fits and the trend charts exclude it.
- Timestamps keep full fidelity (ISO 8601 with offset) through raw and
  staging (`_ts` columns, TIMESTAMPTZ); truncation to a calendar day
  (`_dt`) happens as far downstream as possible, at the point of use, and
  buckets by UTC day.
- **Two fix populations, one link.** A *documented* fix is a release-notes item
  (`fct_fixes`, via `int_fix_reps`): it exists only once the release ships and
  the notes author decides what gets an item. A *committed* fix is a distinct
  non-housekeeping stable-branch commit subject (`dim_commit.fix_key`,
  `int_committed_fixes`): it exists the moment it lands, and belongs to the
  release it ships in (tag ancestry) or to the open release (not yet tagged).
  The notes fold several commits into one item and document only ~40-60% of
  committed subjects (`dim_release.documentation_rate`), so the two counts are
  never equal; the notes' commit annotations link them (`is_documented`). The
  origins face keeps the two apart: "Fix origins per release" plots documented
  fixes for shipped releases, "Fix commits per release" plots committed fixes
  for every release including the open one's so-far bar, so each chart compares
  like with like (`fct_fix_origins_agg` carries both; the documented-units
  forecast of the open release is `fct_fix_projections`' origin_scaled method).
- **Thread identity is transitive.** A message's parent is its In-Reply-To
  (else the last References id) and the thread root is the topmost archived
  ancestor reached by climbing that chain within the list
  (`int_message_threads`). Taking the first References id as the root -- the
  former rule -- split threads whenever a client sent only the parent, which
  fragmented pgsql-hackers into ~27.5k "threads" instead of ~12.8k and left the
  fix-linked share of messages at ~48% instead of ~66%. A *bug report* is a new
  pgsql-bugs thread (`fct_threads.is_new_thread`), form or free-form; the BUG #
  form reports alone (`dim_bug`) are about two thirds of them.
- **Reports link to fixes exactly, not fuzzily**: commit messages carry
  `Discussion: https://postgr.es/m/<message-id>` trailers (and sometimes
  `Bug: #NNNNN`), extracted by `int_commit_discussions` /
  `int_commit_bug_links` from the bodies already in `raw`. A pgsql-bugs
  report counts as acted upon when any message of its thread is cited by
  a commit, or the bug number is mentioned.
- **The scrapers are pure extraction** — fields land raw verbatim. Every
  derivation lives in the transform: the AI-credit flag
  (`int_git_commits`), CVE extraction (`int_fix_items`), release-tag
  filtering and major/minor parsing (`stg_git_tags`), per-release item
  counts for the out-of-band rule (`int_releases`).
- Stable-branch commit series count only post-`.0` commits (the backpatch
  stream); shared pre-branch history belongs to `master`. Security fixes are
  embargoed and reach public git only on wrap day, so mid-cycle security
  volume is structurally invisible.
- The release notes are parsed from the clone's SGML at build time
  (`pg_analysis.sources.sgml` -> `raw_release_items` / `raw_item_commits`), the primary
  source. The retired HTML scraper (`archive/scrape_release_notes.py`, from
  postgresql.org) parses the same notes and is kept only as a manual
  cross-check reference (not wired into the build, not maintained). Validated
  2026-08-28, when the corpus held 19 shipped releases: identical version
  coverage, dates, and CVE sets, and the commit-annotation dedup now used by
  the transform models (match on summary text OR the exact annotation block)
  reproduced the pure-text counts exactly (Aug 2026: 142 both ways). Known
  divergence: nested remediation sub-bullets (e.g. CVE-2024-4317's three
  steps) fold into their parent item in SGML instead of counting as separate
  fixes — a correction.

## Tooling note: dbt charts (formerly dataface)

The visualization layer is the tool documented at
[docs.dbtcharts.com](https://docs.dbtcharts.com/): **`dbt-charts` 0.7.0**,
CLI **`dct`**, project config `dbt_charts.yml`. It was previously published
on PyPI as `dataface` (0.4.0, CLI `dft`) — never install the two together
(shared `d3_format`/`mdsvg` modules clobber each other; see requirements.txt).
0.6.0 removed MetricFlow support, so every face is plain SQL; queries name
models with `{{ ref('model') }}` (resolved through `target/manifest.json`,
which also lets `dct validate` check each query's columns against the
compiled models -- run `dbt parse` after renaming a column, and keep every
mart's outermost projection explicit so that check can read it) against the
read-only `warehouse` DuckDB source. Boards carry an informational
`_schema_version` stamp written by `dct migrate`; never edit it by hand, and
rerun `dct migrate charts/` after an upgrade (0.7.0 needed no rewrite, so the
stamps still read 0.6.0). The dct agent skills install into the gitignored
`.claude/skills/dct-*/` via `dct init skills claude`; rerunning it after an
upgrade refreshes them and sweeps retired ones.

Quirks that still shape the boards:

- No native trendlines: the `*_trend` queries compute least-squares fits in
  DuckDB SQL (`REGR_SLOPE`/`REGR_INTERCEPT`) and draw them as dashed line
  layers with explicit stroke colors.
- Layer labels are appended to the y-axis title; keep them short or a chart
  can collapse to a sliver.
- Multi-series `y: [a, b]` with `color:` draws one series per measure x
  category, named "<category> - <measure>"; the list-traffic charts use it
  instead of unpivoting in SQL.
- Fixed upstream, so no longer worked around: bars on a temporal x-axis
  overhanging the axis ends (0.6.0; the `*_pad` scatter layers are gone),
  `sort:` being ignored on charts with `layers:` and on line/area charts
  (0.7.0; the layered fix-commits chart now carries an explicit `sort:`),
  overlay layers collapsing multi-series tooltips into one row (0.7.0), and
  facet panels wrapping axis titles mid-word (0.7.0; titles now ellipsize).
- Hover emphasis (0.7.0) dims the other marks and drops a guide line on
  every chart family by default; it can be switched off per board with
  `style.charts.hover_emphasis.visible: false`.
