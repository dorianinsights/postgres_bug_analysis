# PostgreSQL patch analysis

Is Postgres fixing more, faster — and is LLM-assisted bug discovery behind it?
This pipeline scrapes the primary sources, persists them as CSVs, and renders
the analysis as [dataface / dbt charts](https://docs.dbtcharts.com/) dashboards.

Three explicit stages, each re-runnable on its own:

```
scrape_cve_severity.py ──> data/raw/cve_severity.csv ─┐
postgres_clone.py ──> .cache/postgres.git ────────────┼─> transform/ (dbt+DuckDB) ──> transform.duckdb marts ──> faces/*.yml (dct)
                      (full bare clone: commits,       │        │ (typed tables — what the faces read)           (visualization)
                       tags, AND release-notes SGML)   │        └────> data/derived/*.csv (diffable audit export)
mailing_list_sync.py ──> .cache/mbox/ ────────────────┘
                      (monthly mbox archives)
                      (all read directly at build time)
```

## Quickstart

```bash
# One-time setup (venv lives at the repo root; Python 3.10-3.13 — 3.14 not yet
# supported by dbt-charts)
python3.12 -m venv venv
./venv/bin/pip install -r requirements.txt

# 1. Sync the postgres clone (first run: full bare clone, ~800MB). The
#    release notes are parsed straight from its SGML at dbt build time
#    (step 2) — no separate extraction step, no HTTP.
./venv/bin/python postgres_clone.py

#    Sync the pgsql-bugs + pgsql-hackers mbox archives (full message
#    bodies; hackers is ~3GB on first sync). Needs a free postgresql.org
#    community account: put POSTGRES_COMM_USERNAME / POSTGRES_COMM_PASSWORD
#    in .env (gitignored). Past months are cached forever; only the
#    current month is re-fetched.
./venv/bin/python mailing_list_sync.py

#    Scrape the published CVSS severity ratings for PostgreSQL's CVEs
#    (one small HTTP fetch; overwrites data/raw/cve_severity.csv).
./venv/bin/python scrape_cve_severity.py

# 2. Derive analysis datasets (dbt project; profiles.yml is local to the
#    directory, so no ~/.dbt setup is needed; deps installs dbt_utils +
#    dbt_expectations, one-time per clone)
(cd transform && ../venv/bin/dbt deps && ../venv/bin/dbt build)

# 3. Visualize (run from this directory — dbt_charts.yml anchors the project)
./venv/bin/dct validate faces/*.yml
./venv/bin/dct render faces/*.yml --format html --output "out/{stem}.html"
./venv/bin/dct serve          # or: live preview in the browser
```

## Data files (`data/`)

Two subdirectories, one per pipeline direction: `data/raw/` holds the one
external CSV (`cve_severity.csv`) read by a dbt source; `data/derived/` holds the
CSV **audit exports** of the mart tables — committed and line-diffable in
review, but read back by nothing (the faces read the typed mart tables in
`transform/transform.duckdb` instead, so DATE/DOUBLE/BIGINT typing survives
end to end with no re-casting). Nothing writes and reads the same directory. **Git-side and mail-side data have no CSV landing layer at all**:
the clone at `.cache/postgres.git` is content-addressed and immutable — its
own perfect raw store — so the transform's `models/raw_git/` Python models
(commits, tags, AND the release-notes SGML, via `gitsource` / `sgmlsource`)
read it directly at build time, and every git-derived table shares one
consistent snapshot of the clone. Likewise the monthly mbox files at
`.cache/mbox/` (immutable once a month is past) are decoded directly by
`models/raw_mail/`. The mboxes replaced scraping the web archive's monthly
index pages, which silently cap at 200 messages per page — the index route
had lost ~28% of pgsql-bugs messages — and they carry full bodies and
threading headers the indexes never had. pgsql-hackers joined pgsql-bugs
in the sync so commit Discussion: trailers can be resolved to their
source list (the origin-attribution models).

Raw (`data/raw/`, the one external CSV — rerun `scrape_cve_severity.py` to refresh):

| File | Grain | Source |
|---|---|---|
| `cve_severity.csv` | one published PostgreSQL CVE | `scrape_cve_severity.py` from postgresql.org/support/security: CVSS v3 base score + vector + component (the NONE/LOW/MEDIUM/HIGH/CRITICAL band is derived downstream) |

Derived (`data/derived/`, the CSV audit exports of the mart tables, written
by the transform's on-run-end hook — rerun `dbt build` to change analysis
rules without re-scraping; one `.csv` per mart, same name). Only marts under
`var('derived_csv_max_rows')` (1000) rows get a twin — the heavier ones
(`fct_messages`, `fct_commits`, `dim_person`, `dim_date`, `dim_bug`,
`fct_fixes`, `bridge_fix_contributor`) live only as typed tables in the warehouse:

| File | Grain | Notes |
|---|---|---|
| `fct_wave_categories_agg.csv` | (dim_release_key, category) | distinct-fix counts per category, aggregated from `fct_fixes`; conformed to `dim_release` via `dim_release_key` |
| `fct_wave_contributors_agg.csv` | (dim_release_key, contributor) | credit counts via `bridge_fix_contributor` (the notes' "(Name, Name)" parse lives in `int_fix_contributors`), with first-seen wave; conformed to `dim_release` |
| `projections.csv` | one scenario | next-wave scenarios: reversion / trend / regime repeat / escalation |
| `fct_category_vs_subsystem_agg.csv` | (category, subsystem) | the agreement matrix validating the keyword categorizer against changed-file paths |
| `fct_bug_reports_monthly_agg.csv` | one month | pgsql-bugs report volume vs acted-upon rate (recent months right-censored) |
| `fct_fix_origins_agg.csv` | (wave, origin) | distinct fixes traced via Discussion:/Bug: trailers to pgsql-bugs, pgsql-hackers, or unknown/other/internal |
| `fct_origin_activity_monthly_agg.csv` | (month, origin) | master-branch activity by origin: non-plumbing commits, AI-flagged commits, distinct cited threads |
| `fct_pending_fix_origins_agg.csv` | (ships_at, origin) | the in-progress next wave: backpatched fixes committed since the last wrap but not yet released, by origin — the "committed so far" bar on the origins chart (no security yet: embargoed until wrap) |
| `dim_version.csv` | one version | version dimension: one row per individual minor (e.g. `18.6`) below the wave — major/minor, wrap + announced date, `dim_release_key` → `dim_release` (NULL for `.0` majors), and its dates conform to `dim_date` |
| `fct_version_items_agg.csv` | one version | aggregate fact: changelog item count per minor, conformed to `dim_version` (the date/major/minor attributes live in the dimension) |
| `dim_cve.csv` | one CVE | CVE dimension: CVSS v3 base score + band + vector + component for every CVE a corpus fix cites |
| `bridge_fix_cve.csv` | (fix, CVE) | bridge for the fix<->CVE many-to-many |
| `bridge_fix_bug.csv` | (fix, bug) | bridge for the fix<->bug many-to-many |
| `dim_release.csv` | one wave | the release dimension (unifies the retired dim_release_wave, dim_release_cycle, and fct_release_cycles): `status` = shipped/open/future, wave scale (fixes/CVEs/security) + flags for shipped rows, wrap date, plus the cycle signals (early reports/messages/fixes, pace, window) folded onto the started scheduled cycles; keyed `dim_release_key` (a generate_surrogate_key hash) |

(The message-grain `fct_messages` mart has **no** CSV twin — one row per
archived message is too heavy to commit; its typed table in `transform.duckdb`
is the interface, and `export_marts_csv` skips it.)

## Dashboards (`faces/`)

- `changelog.yml` — the release-notes view: fixes per release by branch,
  category mix (absolute + 100%), out-of-band waves, the security hockey
  stick, contributors first-time-vs-returning, and the next-wave projection
  scenarios.
- `git_activity.yml` — the commit-level view: quarterly distinct backpatched
  fixes, per-branch series, AI-credited commits (chart + full credit-line
  table), and the like-for-like release-cycle pace comparison.
- `bug_reports.yml` — the pgsql-bugs view: monthly report volume with a
  6-month average, weekly volume with a 3-week average, acted-upon
  share, outcome and latency breakdowns, discussion volume by outcome,
  and the most-discussed reports table.
- `origins.yml` — source attribution: fixes per wave by origin (counts
  and share, with an in-progress bar for the next wave's fixes committed so
  far), cited discussion threads per month by source, AI-flagged commits by
  origin — the grounding for report-volume -> fix-volume projections.
- `fix_impact.yml` — impact & severity: security fixes by CVSS band, fix
  size and backpatch breadth by severity, and time-to-fix vs change size —
  how a fix's size and severity relate to its timeline and reach.

Rendered copies land in `out/` (gitignored; regenerate with `dct render`).

## Transform (`transform/`)

A dbt project targeting DuckDB (dbt-duckdb) — run `dbt build` from inside
`transform/`. The raw CSVs are read in place as external sources, and the
marts are typed tables inside `transform.duckdb` — the interface the faces
query (dct's `warehouse` source opens the file read-only) and what dbt tests
run against, so types survive with no sniffing or re-casting. An on-run-end
hook (`macros/export_marts_csv.sql`) then exports every mart to its
`data/derived/*.csv` twin for git-diffable review. `transform.duckdb` itself
stays gitignored — `dbt build` regenerates it — but note DuckDB is
single-writer: close interactive `duckdb` CLI sessions on it before
building. Each layer lives in
its own schema — `raw`, `staging`, `intermediate`, `marts`, `seeds` (the
`generate_schema_name` macro uses the configured names verbatim instead of
dbt's target-prefixed default), so browsing the .duckdb shows the layer in
every object's name. Layers:

- `models/raw_git/` — Python models (dbt-duckdb) that read
  `.cache/postgres.git` directly via `transform/gitsource.py`: commits with
  full message bodies, per-commit `--numstat` file rows, and every
  `REL_1x_*` ref — verbatim strings, one consistent clone snapshot per
  build. Requires the clone (run `postgres_clone.py` or either scraper
  entry point first).
- `models/raw_mail/` — Python model decoding the `.cache/mbox/` archives
  via `transform/mailsource.py`: per message, the bare headers (RFC 2047
  decoded), the Date header as an ISO string with its original offset,
  and the first text body part. Splitting is on the archive's own
  envelope line — stdlib `mailbox` oversplits on the `From <sha>` first
  line of attached git patches. Requires the cache (run
  `mailing_list_sync.py` first).
- `models/staging/` — typed views over the raw CSVs and raw_git tables
  (`stg_*`). The CSV source reader restricts type-sniffing to
  BIGINT/DATE/VARCHAR so version strings like "15.10" can't collapse into
  doubles.
- `models/intermediate/` — the analysis steps as tables: `int_waves` (wave
  grain + flags), `int_fix_items` (fix items + dedup keys + derived CVEs),
  `int_fix_groups` (cross-branch dedup as recursive-CTE connected
  components), `int_fix_reps` (one categorized representative per distinct
  fix), `int_wave_summary`, `int_git_commits` (plumbing/AI-credit flags).
- `models/marts/` — the typed tables the faces and CSV exports read: the
  item-grain `fix_items` fact, the commit-grain `fct_commits`
  fact, the wave/projection/pace rollups, and the star (dims + facts)
  described below. Watch aggregate types here: DuckDB's `SUM(INTEGER)` is HUGEINT,
  which downstream writers silently turn into DOUBLE — cast count-like
  sums to `::BIGINT` at the aggregation site.
  - **Star schema (Kimball).** Alongside those analysis-shaped marts, a
    conformed star sits at the lowest grains: the dimensions `dim_person` (git
    authors + committers + list senders unified to one person, keyed by the
    shared `person_node()` macro + `int_person_map` connected-component
    resolution so several emails collapse to one person), `dim_date`,
    `dim_release` (shipped waves + open/future cycles, status-flagged), `dim_cve` and `dim_bug`, with the
    facts `fct_commits` (commit grain), `fct_messages` (message grain), and
    `fct_fixes` (fix grain). `dim_version` sits one grain below `dim_release`:
    one row per individual minor (e.g. `18.6`), conformed up to its wave via
    `dim_release_key` (NULL for the `.0` majors that ship alone); `fct_fixes` and
    `fct_version_items_agg` carry a `dim_version_key` FK to it.
    **Key convention:** every non-date dimension's PK is its first column, named
    `<table>_key` (`dim_release_key`, `dim_version_key`, `dim_bug_key`,
    `dim_cve_key`, `dim_person_key`) and generated by
    `dbt_utils.generate_surrogate_key` (a uniform VARCHAR hash); facts link back
    with a matching `<table>_key`, role-prefixed where a fact plays the same
    dimension twice (`author_dim_person_key` / `committer_dim_person_key`,
    `primary_dim_bug_key`, `ship_dim_release_key`). `dim_date` is the deliberate
    exception — see below. The cycle grain is not a
    separate fact: a cycle is a release earlier in its life, so its signals ride
    on `dim_release`. The
    fix<->CVE, fix<->bug, and fix<->contributor many-to-manys go through
    `bridge_fix_cve` / `bridge_fix_bug` / `bridge_fix_contributor` (the last
    fed by `int_fix_contributors`); `fct_wave_categories_agg` and `fct_wave_contributors_agg`
    are conformed aggregates of `fct_fixes` (+ the contributor bridge). The period aggregates (`fct_bug_reports_monthly_agg`,
    `fct_list_traffic_monthly_agg`/`weekly`, `fct_origin_activity_monthly_agg`) are aggregate
    facts rolled up from those grains and conformed on `dim_date` by their
    month/week DATE. `dim_date` is keyed on `date_day` (a real DATE) — there is
    no separate integer date surrogate; every mart's date columns join to it
    directly, and a `relationships` test on each one enforces the conformance.
    Referential integrity is enforced by `relationships` tests on every FK, and
    singular tests pin each fact's row count to its grain. Several older marts were superseded as the star grew —
    `fct_fixes` replaced `fix_impact` and `fix_items`; the cycle signals
    (`git_cycle_pace`, `fix_projection_cycles`, `int_cycle_signals`) were unified
    as `fct_release_cycles` and then folded into `dim_release` (`int_release_cycles`).
- `seeds/` — the classification data: `categories` (bucket + display
  order), `category_rules` (ordered case-insensitive RE2 patterns; lowest
  matching `match_order` wins, CVE items bypass the rules),
  `subsystem_rules` (path patterns), and the range-bucket tables
  `latency_windows` / `thread_size_windows` (each range and its label
  defined together; the marts join them, and relationships tests replace
  duplicated label lists).

Analysis parameters live as dbt vars in `dbt_project.yml`
(`scheduled_wave_min_items`, `wave_cadence_days`, `pace_comparison_cycles`,
`wrap_tag_window_days`) plus the shared loose sanity floors the range tests
use (`test_floor_major`, `test_floor_release_dt`, `test_floor_git_ts` —
deliberately NOT the corpus bounds; `corpus.py` owns those). Editing a
parameter changes what the results mean — treat it like a corpus change.

Every model is heavily tested — 295 data tests in all: column-level schema
tests (uniqueness, not-null, relationships, accepted ranges on counts and
dates, regex format checks) using `dbt_utils` and Metaplane's
`dbt_expectations` (installed via `dbt deps`), plus seven singular
reconciliation tests (rollups vs the item grain, commit annotations vs
items, connected-components sanity, exactly one open cycle). `dbt build`
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
  consumer orders explicitly (the faces do; the CSV exporter uses
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

## Linting & type checking

Repo-wide (config in the repo-root `pyproject.toml`, mirroring
property_analysis): `ruff` (format + lint) and `pyright` (strict mode, all files).
SQL style for the dbt models is linted by `sqlfluff` (duckdb dialect + the
**dbt templater**, so package macros like `dbt_date.get_base_dates` expand to
real SQL during lint — it compiles the `transform/` project per run, which
needs the DuckDB file unlocked, same as a build; config in the repo-root
`.sqlfluff`); correctness of the models is
covered by the dbt tests themselves. All three are enforced twice — per-edit
via `.claude/hooks/` (`ruff-lint.sh`, `pyright-check.sh`, `sqlfluff-lint.sh`)
and at commit time by the blocking pre-commit gate (`.pre-commit-config.yaml`;
one-time setup: `./venv/bin/pre-commit install`). Auto-fix layout nits with
`./venv/bin/sqlfluff fix <file>`.

## Analysis conventions

- **The corpus is defined in `corpus.py`** (majors 15-18 and the git-history
  floor) and shared by all three scrapers so their datasets can never
  diverge. Extending the analysis back in time is an edit there — a
  deliberate, versioned commit, not a flag or an env var.
- `.0` feature releases are not fixes; "update time zone data files" items are
  routine refreshes — both excluded.
- A wave is **out-of-band** (emergency re-release) when its largest release has
  fewer than 20 items; out-of-band waves are excluded from trend/pace series.
- Cross-branch dedup: two items in a wave are the same fix when EITHER their
  normalized summary text (lowercased, whitespace collapsed, "§" markers
  stripped) OR their exact annotated commit-hash set matches, transitively
  (connected components in `int_fix_groups.sql` — its header comment
  documents the four real-world cases behind the rule).
- The corpus's first wave (15.1, Nov 2022) accumulated only ~4 weeks of fixes
  and is flagged `is_partial_window`; projection fits exclude it.
- Timestamps keep full fidelity (ISO 8601 with offset) through raw and
  staging (`_ts` columns, TIMESTAMPTZ); truncation to a calendar day
  (`_dt`) happens as far downstream as possible, at the point of use, and
  buckets by UTC day.
- **Reports link to fixes exactly, not fuzzily**: commit messages carry
  `Discussion: https://postgr.es/m/<message-id>` trailers (and sometimes
  `Bug: #NNNNN`), extracted by `int_commit_discussions` /
  `int_commit_bug_refs` from the bodies already in `raw`. A pgsql-bugs
  report counts as acted upon when any message of its thread is cited by
  a commit, or the bug number is mentioned.
- **The scrapers are pure extraction** — fields land raw verbatim. Every
  derivation lives in the transform: plumbing/AI-credit flags
  (`int_git_commits`), CVE extraction (`int_fix_items`), release-tag
  filtering and major/minor parsing (`stg_git_tags`), per-release item
  counts for the out-of-band rule (`int_waves`).
- Stable-branch commit series count only post-`.0` commits (the backpatch
  stream); shared pre-branch history belongs to `master`. Security fixes are
  embargoed and reach public git only on wrap day, so mid-cycle security
  volume is structurally invisible.
- The release notes are parsed from the clone's SGML at build time
  (`sgmlsource` -> `raw_release_items` / `raw_item_commits`), the primary
  source. `scrape_release_notes.py` (HTML from postgresql.org) parses the same
  notes and is kept as an independent manual cross-check (its output is not
  wired into the build). Validated 2026-08-28: identical version coverage,
  dates, and CVE sets,
  and the commit-annotation dedup now used by the transform models (match on
  summary text OR the exact annotation block) reproduces the pure-text
  counts exactly across all 19 waves (Aug 2026: 142 both ways). Known divergence: nested remediation
  sub-bullets (e.g. CVE-2024-4317's three steps) fold into their parent item
  in SGML instead of counting as separate fixes — a correction.

## Tooling note: dbt charts (formerly dataface)

The visualization layer is the tool documented at
[docs.dbtcharts.com](https://docs.dbtcharts.com/): **`dbt-charts` 0.5.0**,
CLI **`dct`**, project config `dbt_charts.yml`. It was previously published
on PyPI as `dataface` (0.4.0, CLI `dft`) — never install the two together
(shared `d3_format`/`mdsvg` modules clobber each other; see requirements.txt).

Quirks that still shape the faces (details in `dbt_charts_bug_report.md`):

- Bars on a temporal x-axis overhang the axis end (0.5.0 fixed the left edge
  and the dropped-labels bug; the right edge still clips). Each bar chart
  carries an invisible zero-opacity scatter layer (`*_pad` queries) padding
  the x-scale domain — the note at the top of `faces/changelog.yml` explains
  the pattern.
- No native trendlines: the `*_trend` queries compute least-squares fits in
  DuckDB SQL (`REGR_SLOPE`/`REGR_INTERCEPT`) and draw them as dashed line
  layers with explicit stroke colors.
- Layer labels are appended to the y-axis title; keep them short or a chart
  can collapse to a sliver.
- Multi-series `y: [a, b]` lists are unreliable — unpivot in SQL and use the
  `color:` channel; charts take `height:` (no `aspect_ratio:`).
