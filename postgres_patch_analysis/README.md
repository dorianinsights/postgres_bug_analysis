# PostgreSQL patch analysis

Is Postgres fixing more, faster — and is LLM-assisted bug discovery behind it?
This pipeline scrapes the primary sources, persists them as CSVs, and renders
the analysis as [dataface / dbt charts](https://docs.dbtcharts.com/) dashboards.

Three explicit stages, each re-runnable on its own:

```
scrape_release_notes_sgml.py ─┐
                              ├─> data/raw/*.csv ──> transform/ (dbt+DuckDB) ──> data/derived/*.csv ──> faces/*.yml (dct)
scrape_git_commits.py ────────┘    (scraper output)                              (mart output)          (visualization)
```

## Quickstart

```bash
# One-time setup (venv lives at the repo root; Python 3.10-3.13 — 3.14 not yet
# supported by dbt-charts)
python3.12 -m venv ../venv
../venv/bin/pip install -r requirements.txt

# 1. Scrape (git first run clones ~140MB metadata, then fetches; the SGML
#    release-notes extractor reads from that same clone — no HTTP)
../venv/bin/python scrape_git_commits.py
../venv/bin/python scrape_release_notes_sgml.py

# 2. Derive analysis datasets (dbt project; profiles.yml is local to the
#    directory, so no ~/.dbt setup is needed)
(cd transform && ../../venv/bin/dbt build)

# 3. Visualize (run from this directory — dbt_charts.yml anchors the project)
../venv/bin/dct validate faces/*.yml
../venv/bin/dct render faces/*.yml --format html --output "out/{stem}.html"
../venv/bin/dct serve          # or: live preview in the browser
```

## Data files (`data/`)

Two subdirectories, one per pipeline direction: `data/raw/` is written by the
scrapers and read by the dbt sources; `data/derived/` is written by the dbt
external mart models and read by the faces (which also read `raw/` directly
for commit-level charts). Nothing writes and reads the same directory.

Raw (`data/raw/`, from the scrapers — rerun the scraper to refresh):

| File | Grain | Source |
|---|---|---|
| `releases.csv` | one minor release | release-notes SGML sources in postgres.git (`doc/src/sgml/release-NN.sgml` per stable branch), majors 15-18 |
| `release_items.csv` | one changelog item | same sources: summary, full text, CVE ids |
| `item_commits.csv` | one (item, branch-commit) | the SGML comment annotations: author + every branch each fix landed on, with commit hash — ground truth linking changelog items to git commits |
| `git_commits.csv` | one commit per branch | postgres.git `REL_15..18_STABLE` (post-`.0` backpatches) + `master`, with plumbing flag and any AI-tool credit line from the message body |
| `git_tags.csv` | one minor-release tag | postgres.git `REL_1x_y` tags (tag date = the wrap moment) |

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
producer changed) plus the item-grain `fix_items.csv`. Layers:

- `models/staging/` — typed views over the raw CSVs (`stg_*`). The source
  reader restricts type-sniffing to BIGINT/DATE/VARCHAR so version strings
  like "15.10" can't collapse into doubles.
- `models/intermediate/` — the analysis steps as tables: `int_waves` (wave
  grain + flags), `int_fix_items` (fix items + dedup keys), `int_fix_groups`
  (cross-branch dedup as recursive-CTE connected components), `int_fix_reps`
  (one categorized representative per distinct fix), `int_wave_summary`.
- `models/marts/` — the external models, each a `-> data/derived/*.csv` writer:
  the item-grain `fix_items` fact plus the five wave/projection/pace
  rollups.
- `seeds/` — the categorization taxonomy: `categories` (bucket + display
  order) and `category_rules` (ordered case-insensitive RE2 patterns; lowest
  matching `match_order` wins, CVE items bypass the rules).

Every model carries schema tests (uniqueness, not-null, relationships,
accepted values — 66 in all), so `dbt build` is also the validation pass.
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
