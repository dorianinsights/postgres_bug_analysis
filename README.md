# PostgreSQL patch analysis

Is Postgres fixing more bugs, faster — and is LLM-assisted bug discovery
behind it?

This project answers that question from public data: the PostgreSQL git
repository (its commits, tags and release-notes sources), the two busiest
mailing lists (pgsql-bugs and pgsql-hackers), and the CVSS severity ratings
postgresql.org publishes for each CVE. A [dbt](https://www.getdbt.com/)
project on [DuckDB](https://duckdb.org/) turns those sources into a set of
analysis tables, and [dbt charts](https://docs.dbtcharts.com/) renders them
as interactive dashboards.

## What you get

Eight dashboards under `charts/`, served locally by `dct serve`:

- **Fix analysis** (`1_fix_analysis.yml`) — where fixes come from: documented
  and committed fixes per release by origin, and AI-flagged commits by origin.
- **Changelog** (`changelog.yml`) — the release-notes view: fixes per release,
  category mix, out-of-band releases, security fixes, contributors, and the
  next-release projection.
- **Git activity** (`git_activity.yml`) — the commit-level view: backpatched
  fixes per quarter, codebase size and churn by subsystem, commits disclosing
  AI involvement, release-cycle pace.
- **Bug reports** (`bug_reports.yml`) — pgsql-bugs volume, acted-upon share,
  outcomes and latency.
- **Projected fixes** (`projected_fixes.yml`) — a forecast of the next
  scheduled minor release, backtested over the shipped ones.
- **Email list analysis** (`email_list_analysis.yml`) — list traffic, what new
  pgsql-hackers threads lead to, and threads disclosing AI involvement.
- **Fix impact** (`fix_impact.yml`) — security fixes by CVSS band, fix size
  and backpatch breadth by severity, time-to-fix.
- **The article** (`article_llms_postgres.yml`) — the write-up "AI, LLMs, and
  the Pace of Postgres Bug Fixing" as a board, each figure a live chart.

## How it works

Three fetch stages feed one dbt build, and the dashboards read the result:

```
pg-cve-scrape ──> data/raw/cve_severity.csv ─┐
pg-clone ──> .cache/postgres.git ────────────┼─> dbt build ──> transform.duckdb ──> charts/*.yml (dct)
             (full bare clone: commits,      │        │        (typed mart tables)
              tags, AND release-notes SGML)  │        └──────> data/derived/*.csv (diffable audit export)
pg-mail-sync ──> .cache/mbox/ ───────────────┘
             (monthly mbox archives)
```

- **Fetch.** `pg-clone` keeps a full bare clone of the postgres repo;
  `pg-mail-sync` keeps monthly mbox archives of the two lists; `pg-cve-scrape`
  writes one small CSV. Each is independent, idempotent and cached, so a
  refresh only fetches what changed.
- **Transform.** `dbt build` reads the clone and the mbox archives directly,
  types and joins everything through staging, intermediate and mart layers,
  tests every model, and writes the marts as typed tables into
  `transform.duckdb`. Small marts also get a diffable CSV twin in
  `data/derived/`.
- **Visualize.** The boards in `charts/` are plain YAML with SQL queries
  against the marts. `dct serve` renders them live in the browser;
  `dct render` exports static HTML.

`pg-refresh` runs the three fetches and then the build in one command.

## Quickstart

```bash
# 1. One-time setup. Python 3.10-3.13 (3.14 is not yet supported by
#    dbt-charts). requirements.txt pins every dependency and installs the
#    repo's own pg_analysis package, which puts the pg-* commands in venv/bin.
#    The mailing-list sync needs a free postgresql.org community account:
#    put POSTGRES_COMM_USERNAME / POSTGRES_COMM_PASSWORD in .env (gitignored).
python3.12 -m venv venv
./venv/bin/pip install -r requirements.txt

# 2. Fetch the sources and build the marts. The first run is slow: the bare
#    clone is ~800MB and the pgsql-hackers archive ~3GB. Later runs only
#    fetch what changed. profiles.yml sits at the repo root, so no ~/.dbt setup.
./venv/bin/pg-refresh

# 3. Open the dashboards in the browser.
./venv/bin/dct serve
```

Running a stage on its own:

```bash
./venv/bin/pg-refresh --list          # the steps, in run order
./venv/bin/pg-refresh --only cve      # one fetch, then the build
./venv/bin/pg-refresh --skip mail     # everything but the slow mbox sync (needs an existing .cache/mbox/)
./venv/bin/pg-refresh --no-build      # refresh the sources without rebuilding
./venv/bin/pg-clone                   # or one fetch by itself: pg-clone / pg-mail-sync / pg-cve-scrape
./venv/bin/dbt build                  # just the transform (dbt build --select <models> while iterating)
./venv/bin/dct validate charts/*.yml  # check the boards after editing one
./venv/bin/dct render charts/*.yml --format html --output "out/{stem}.html"   # static HTML into out/ (gitignored)
```

## Optional: local LLM classification (Ollama)

Three tables are labeled by a local LLM through [Ollama](https://ollama.com):
the fix content taxonomy, and disclosed AI involvement per committed fix and
per mailing-list thread. The labels are cached in committed CSVs under
`data/raw/`, keyed by a hash of the text, so **a fresh clone needs no Ollama
at all**: the build reads the cache, marks any text the cache has never seen
as unclassified, and succeeds with a warning saying how many are waiting.

To label new texts yourself, install Ollama, `ollama pull qwen3:30b-a3b`, and
rebuild. A build classifies a small number of new texts inline; a large batch
(a new major, a prompt change) goes through the resumable `pg-backfill-ai`
and `pg-backfill-categories` commands.

## Repository layout

```
python/pg_analysis/   the Python package: corpus definition, the fetchers, pg-refresh,
                      the LLM backfills, and the readers the dbt Python models import
python/tests/         its unit tests (./venv/bin/pytest)
models/               the dbt models: raw_git/, raw_mail/, staging/, intermediate/, marts/
seeds/                classification data: fix categories, AI-involvement roles and
                      hand reviews, subsystem and file-class rules, bucket tables
macros/  tests/       dbt macros and singular tests
vars.yml              every analysis parameter (thresholds, windows, release schedule)
charts/               the dashboards (dbt charts YAML)
data/raw/             the CSVs the build reads: the CVE scrape and the LLM label caches
data/derived/         CSV audit exports of the small marts (written by the build, read by nothing)
.cache/               the git clone and mbox archives (gitignored)
transform.duckdb      the warehouse (gitignored; dbt build regenerates it)
```

## Developing

Every edit is checked twice, per edit by the hooks in `.claude/hooks/` and at
commit by the pre-commit gate (`./venv/bin/pre-commit install` once): ruff
and pyright for Python, sqlfluff for SQL, `dct validate` for the boards, and
pytest for the package. `dbt build` is also the validation pass for the
models themselves.

The architecture, the modelling decisions, the naming conventions and the
operational gotchas are documented in `CLAUDE.md`. Open work is in `TODO.md`.

## License

Dual-licensed, by content type:

- **Code** (the Python package, the dbt models, macros and tests, the boards,
  the configuration and the documentation) is under the MIT License, see
  `LICENSE`.
- **Data** (everything under `data/`, the seed CSVs under `seeds/`) and the
  article text in `charts/article_llms_postgres.yml` are under the Creative
  Commons Attribution 4.0 International License (CC BY 4.0), see
  `LICENSE-DATA`. Attribute reuse to Dorian Insights, L.L.C. with a link to
  this repository.

Copyright (c) 2026 Dorian Insights, L.L.C. The licensing is also declared
machine-readably in `REUSE.toml` (the [REUSE](https://reuse.software/)
specification), and `CITATION.cff` gives a citation for the analysis.
