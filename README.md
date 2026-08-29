# PostgreSQL patch analysis

Is Postgres fixing more, faster — and is LLM-assisted bug discovery behind it?
This pipeline scrapes the primary sources, persists them as CSVs, and renders
the analysis as [dataface / dbt charts](https://docs.dbtcharts.com/) dashboards.

Three explicit stages, each re-runnable on its own:

```
scrape_release_notes_sgml.py ──> data/raw/*.csv ──────┐
                                 (scraper output)     │
postgres_clone.py ──> .cache/postgres.git ────────────┼─> transform/ (dbt+DuckDB) ──> data/derived/*.csv ──> faces/*.yml (dct)
                      (full bare clone)               │    (mart output)                                     (visualization)
mailing_list_sync.py ──> .cache/mbox/ ────────────────┘
                      (monthly mbox archives)
                      (both caches are read directly at build time)
```

## Quickstart

```bash
# One-time setup (venv lives at the repo root; Python 3.10-3.13 — 3.14 not yet
# supported by dbt-charts)
python3.12 -m venv venv
./venv/bin/pip install -r requirements.txt

# 1. Sync the postgres clone (first run: full bare clone, ~800MB) and
#    extract the release notes from it (no HTTP; the SGML extractor also
#    syncs the clone itself, so this is one step)
./venv/bin/python scrape_release_notes_sgml.py

#    Sync the pgsql-bugs mbox archives (full message bodies). Needs a free
#    postgresql.org community account: put POSTGRES_COMM_USERNAME /
#    POSTGRES_COMM_PASSWORD in .env (gitignored). Past months are cached
#    forever; only the current month is re-fetched.
./venv/bin/python mailing_list_sync.py

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

Two subdirectories, one per pipeline direction: `data/raw/` is written by the
release-notes scraper and read by the dbt sources; `data/derived/` is written
by the dbt external mart models and read by the faces (the changelog face
also reads `raw/releases.csv` directly). Nothing writes and reads the same
directory. **Git-side and mail-side data have no CSV landing layer at all**:
the clone at `.cache/postgres.git` is content-addressed and immutable — its
own perfect raw store — so the transform's `models/raw_git/` Python models
read it directly at build time, and every git-derived table shares one
consistent snapshot of the clone. Likewise the monthly mbox files at
`.cache/mbox/` (immutable once a month is past) are decoded directly by
`models/raw_mail/`. The mboxes replaced scraping the web archive's monthly
index pages, which silently cap at 200 messages per page — the index route
had lost ~28% of pgsql-bugs messages — and they carry full bodies and
threading headers the indexes never had.

Raw (`data/raw/`, from the release-notes scraper — rerun it to refresh):

| File | Grain | Source |
|---|---|---|
| `releases.csv` | one minor release | release-notes SGML sources in postgres.git (`doc/src/sgml/release-NN.sgml` per stable branch), majors 15-18 |
| `release_items.csv` | one changelog item | same sources: summary and full text (CVE ids are derived downstream) |
| `item_commits.csv` | one (item, branch-commit) | the SGML comment annotations: author + every branch each fix landed on, with commit hash — ground truth linking changelog items to git commits |

Derived (`data/derived/`, written by the `transform/` dbt project's external
models — rerun `dbt build` to change analysis rules without re-scraping):

| File | Grain | Notes |
|---|---|---|
| `fix_items.csv` | one distinct fix per wave | the item-grain fact the wave rollups aggregate: the deduped representative item with category, CVEs, and backpatch breadth (`n_branch_items`) |
| `wave_summary.csv` | one same-day release wave | distinct fixes (deduped across branches), CVEs, security count, out-of-band + partial-window flags |
| `wave_categories.csv` | (wave, category) | keyword-rule buckets from the `category_rules` seed; CVE / hardening checked first |
| `wave_contributors.csv` | (wave, contributor) | credits parsed from the notes' trailing "(Name, Name)" lists, with first-seen wave |
| `projections.csv` | one scenario | next-wave scenarios: reversion / trend / regime repeat / escalation |
| `git_cycle_pace.csv` | one release cycle | distinct fixes in each cycle's first N days (N = the open cycle's age) vs full totals |
| `git_commits_enriched.csv` | one commit per branch | the commit-grain export the git face reads: UTC-day `commit_dt` plus the derived `is_plumbing` / `ai_credit` flags |
| `fix_change_profiles.csv` | one distinct fix | what the fix's representative commit changed: files/lines, test + docs involvement, and the path-derived `dominant_subsystem` alongside the keyword category |
| `category_vs_subsystem.csv` | (category, subsystem) | the agreement matrix validating the keyword categorizer against changed-file paths |
| `bug_report_outcomes.csv` | one BUG #NNNNN report | was the report acted upon (linked to a commit via its thread's Discussion: trailer or a bug-number mention), first linked commit day, report-to-fix latency |
| `bug_reports_monthly.csv` | one month | pgsql-bugs report volume vs acted-upon rate (recent months right-censored) |

## Dashboards (`faces/`)

- `changelog.yml` — the release-notes view: fixes per release by branch,
  category mix (absolute + 100%), out-of-band waves, the security hockey
  stick, contributors first-time-vs-returning, and the next-wave projection
  scenarios.
- `git_activity.yml` — the commit-level view: quarterly distinct backpatched
  fixes, per-branch series, AI-credited commits (chart + full credit-line
  table), and the like-for-like release-cycle pace comparison.

Rendered copies land in `out/` (gitignored; regenerate with `dct render`).

## Transform (`transform/`)

A dbt project targeting DuckDB (dbt-duckdb) — run `dbt build` from inside
`transform/`. The raw CSVs are read in place as external sources (nothing is
loaded into the scratch `.duckdb` file), and the derived CSVs are written by
`external`-materialized mart models to `data/derived/` — the five files
build_datasets.py used to produce (same columns, so the faces don't know the
producer changed) plus the item-grain `fix_items.csv`. Each layer lives in
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
- `models/marts/` — the external models, each a `-> data/derived/*.csv` writer:
  the item-grain `fix_items` fact, the commit-grain `git_commits_enriched`
  export, and the five wave/projection/pace rollups.
- `seeds/` — the categorization taxonomy: `categories` (bucket + display
  order) and `category_rules` (ordered case-insensitive RE2 patterns; lowest
  matching `match_order` wins, CVE items bypass the rules).

Every model is heavily tested — 294 data tests in all: column-level schema
tests (uniqueness, not-null, relationships, accepted ranges on counts and
dates, regex format checks) using `dbt_utils` and Metaplane's
`dbt_expectations` (installed via `dbt deps`), plus seven singular
reconciliation tests (rollups vs the item grain, commit annotations vs
items, connected-components sanity, exactly one open cycle). `dbt build`
is therefore also the validation pass. Join style: always an explicit
join type with `ON` conditions — `USING` is forbidden (sqlfluff ST07).
This project replaced `build_datasets.py` + `categorize.py` on 2026-08-28;
at cutover every derived CSV was verified field-identical against the
Python implementation's output (the only byte difference: the csv module
wrote CRLF line endings, DuckDB writes LF).

## Linting & type checking

Repo-wide (config in the repo-root `pyproject.toml`, mirroring
property_analysis): `ruff` (format + lint) and `pyright` (strict mode, all files).
Enforced twice — per-edit via `.claude/hooks/` and at commit time by the
blocking pre-commit gate (`.pre-commit-config.yaml`; one-time setup:
`./venv/bin/pre-commit install`). SQL style for the dbt models follows the
repo-root `.sqlfluff` (duckdb dialect); correctness of the models is covered
by the dbt tests themselves.

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
  and is flagged `partial_window`; projection fits exclude it.
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
  counts for the out-of-band rule (`int_waves`). The scraper's `n_items`
  column survives in raw only as a scrape-consistency checksum, enforced
  by `assert_release_items_match_n_items`.
- Stable-branch commit series count only post-`.0` commits (the backpatch
  stream); shared pre-branch history belongs to `master`. Security fixes are
  embargoed and reach public git only on wrap day, so mid-cycle security
  volume is structurally invisible.
- `scrape_release_notes_sgml.py` (SGML from the git clone) is the primary
  release-notes source; `scrape_release_notes.py` (HTML from postgresql.org)
  writes the same two CSVs and is kept as an independent cross-check.
  Validated 2026-08-28: identical version coverage, dates, and CVE sets,
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
