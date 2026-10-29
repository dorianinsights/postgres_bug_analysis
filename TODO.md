# TODO — outstanding work

Work still remaining for this repo. See `CLAUDE.md` for the architecture,
standing conventions and gotchas. Keep this file to open items only: when
something ships, delete its section rather than annotating it.

## Capture fix `Reported-by:` credits (`bridge_fix_reporter`)

`fct_fixes` drops the `Reported-by:` commit trailers. A fix links to a reporter
only via `primary_bug_number` (→ `dim_bug`), which exists only for public
`BUG #NNNNN` forms. Security fixes never have one — they arrive embargoed and
credit researchers solely through `Reported-by:` — so every CVE fix loses its
reporter list, and 263 corpus fixes carry more than one such trailer.

This is a missing fix→reporter many-to-many, not a `dim_bug` problem (a web-form
bug has exactly one filer, so `dim_bug.reporter_person_key` stays one-per-bug).

Plan (additive, mirrors `bridge_fix_cve` / `bridge_fix_bug`):
- `intermediate/int_fix_reporters.sql` — parse `Reported-by:` trailers from a
  fix's commits; grain `(item_ord, reporter_name, reporter_email)`.
- `marts/bridge_fix_reporter.sql` — grain `(item_ord, person_key)`, each
  reporter resolved through `int_person_map` → `dim_person`. FKs → `fct_fixes`,
  `dim_person`.
- Optionally denormalize `reporter_cnt` onto `fct_fixes`.
- Tests: `unique_combination_of_columns` on the pair; `relationships` from each
  side to its dim and to `fct_fixes`.

## Classify in-progress-major (beta) branch commits: backport vs beta-only stabilization

After the fork, the in-progress major's stable branch receives cherry-picked
fixes exactly like the released branches, plus fixes to code new in that major
and housekeeping. The repo separates the streams only at branch level
(`sources.git.commit_range`; `int_commit_versions` labels the in-progress
branch's commits `development` (version 19.0), and `int_major_development` folds
them into the major's development count). No model labels an individual beta-branch commit, and `fct_fixes` never
sees them (fixes to unreleased code are not documented in any minor notes).

Plan (additive; no change to `fct_fixes` or the projections):
- `intermediate/int_beta_commit_classes.sql` (or a column on `dim_commit`),
  grain `(branch, commit_hash)` for the `dev_status <> 'released'` branch, with
  `commit_class` in {`backport`, `beta_stabilization`, `housekeeping`} from three
  signals, in precedence:
  1. Normalized-subject twin on a released stable branch (the
     `dim_commit.fix_key` rule — exact string, so a reworded subject
     slips through) → `backport`.
  2. Backpatch wording in the body (`Backpatch-through: NN` / `Back-patch to
     all supported`). Naming only the beta major → `beta_stabilization`; naming
     an older major → `backport`.
  3. Origin trailers via `int_commit_origins` (pgsql-bugs → bug fix regardless
     of branch) as a tiebreaker / attribute.
  No master twin at all → `housekeeping` (version stamps, translations).
- The same split applies to master (most master commits have no released-branch
  twin: features, refactoring, fixes to unreleased code) and could be a second
  consumer.
- Possible surfaces: a per-class series on the major-development chart; a
  "beta fixes so far" companion to the pending-release bar, clearly on the
  commit scale rather than the documented-item scale (see the changelog
  upcoming-release item below).

## Parquet-cache the immutable raw parses (mbox + git)

`raw_list_messages` (mbox) and `raw_commit_files` (git) re-parse the entire
history on every build. Both are parallelized across a process `Pool`, but the
work is still redone every run; the mbox parse is the dominant build cost and
`raw_commit_files` is next (bounded by `master`, the one branch a per-branch
fan-out can't split). `raw_branch_size_weekly` is already incremental and is
the pattern to follow.

Cache the immutable parses as Parquet and re-parse only what changed:
- **mbox:** monthly files at `.cache/mbox/<list>/YYYYMM.mbox` are immutable once
  the month is past (the sync re-fetches only the current month). Parse each
  month once to `.cache/mbox_parsed/<list>/YYYYMM.parquet` (skip when the
  parquet is newer than its mbox); re-parse only the current month. DuckDB reads
  Parquet natively, so the mail side drops to seconds.
- **git:** history behind each branch's tip is immutable. Cache per-branch
  numstat/log parses keyed by the branch tip SHA (or make the model
  incremental), re-parsing only commits since the cached tip.

Output must stay byte-identical (parse once, read back). Either incremental
`dbt` models or mtime/SHA-keyed caching inside `sources/mail.py` /
`sources/git.py`.

## Coerce naive email `Date` timestamps to UTC in `sources/mail.py`

A `-0000` `Date` header (RFC 5322: UTC, local zone unknown) makes
`email.utils.parsedate_to_datetime` return a *naive* datetime, so `_sent_ts`'s
`.isoformat()` emits no offset and `stg_list_messages.sent_ts::TIMESTAMPTZ`
falls back to the build machine's session timezone — wrong, and
non-deterministic across build environments. The other timestamped raw sources
preserve their offset; only the mail reader is affected.

Fix in the reader — default a naive parse to UTC:

```python
from datetime import timezone   # add to imports

def _sent_ts(message: EmailMessage) -> str | None:
    try:
        parsed = email.utils.parsedate_to_datetime(message.get("Date", ""))
    except (ValueError, TypeError):
        return None
    if parsed.tzinfo is None:  # a "-0000" Date header: RFC 5322 = UTC, unknown local zone
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.isoformat()
```

Regression check: message `<7f6fabaa-3f8f-49ab-89ca-59fbfe633105@me.com>`
(2022-02-18) is the one known `-0000` row; after the fix its `sent_ts` carries
`+00:00` and its `sent_dt` is 2022-02-18 (currently 2022-02-19 on an HST
machine). Expect a ±1 in at most one message-day count downstream.

## Upcoming release on the changelog "Fixes per Scheduled Minor Release" chart

The chart plots documented changelog `item_cnt` for shipped releases only, so
the upcoming (open) release is absent from the lines. The KPI tiles already show
its committed "fixes so far" (`early_fix_cnt`), but the committed distinct-fix
count runs ~1.5–2.6x the eventual documented `item_cnt` per major, so dropping
it onto the same lines would plot the upcoming release ~2x too tall.

The origins face settled the same question by NOT mixing populations: its
documented chart stops at the last shipped release, and a separate "Fix commits
per release" chart carries the committed measure for every release including
the open one's so-far bar (a dashed-outline bar layer). Follow that here: keep this chart documented-only and add a per-major
committed-fixes-per-release chart with the so-far point
(`dim_commit.dim_release_key` = the open release gives the committed-so-far
count per major). `fct_fix_projections`' origin_scaled method (per-origin
documented-per-early-committed factors over `origin_projection_cycles` cycles)
exists if a documented-units projection is ever wanted instead.

## Pull the commitfest app into the warehouse (`pg-cf-sync`)

https://commitfest.postgresql.org/ tracks every patch through review: the
pipeline BEFORE a commit, which nothing in the warehouse sees today. It
joins to what we have through the mailing-list thread: a patch's threads
are keyed by root message id, the same key as `fct_threads`, and a commit's
`Discussion:` trailer (`int_git_commits.discussion_refs`) closes the loop
thread -> patch -> commit.

What the site exposes (surveyed 2026-09-17; no login needed for any of it):
- **JSON** `/api/v1/commitfests/<id>/patches` — per patch: id, name, status
  in THAT commitfest (Needs review / Waiting on Author / Ready for Committer /
  Committed / Moved to different CF / Returned with feedback / Withdrawn /
  Rejected), authors, last-mail time. Works for every historical commitfest
  (ids run 1..~62, Dec 2014 -> PG20-Final; ~215-336 patches each), so a
  patch's path across commitfests is reconstructible from the per-CF rows.
- **JSON** `/api/v1/patches/<id>/threads` — root message id, subject, latest
  message id/time, has_attachment per attached thread. The join key.
- **JSON** `/api/v1/commitfests/needs_ci` — the open / in-progress / draft
  commitfest ids and dates. (`/api/v1/commitfests` itself 404s; take the id
  list from `/archive/`.)
- **HTML only** `/patch/<id>/` — tags (Bugfix, Performance, ...), target
  version, reviewers, committer, created date, cfbot CI result per platform,
  patch version count and cumulative +/- lines, and the full timestamped
  history (status changes, reviewer/committer assignments, moves, cfbot
  "needs rebase" events). Stable Django template.
- **HTML** `/activity/?page=N` (~100 rows/page, back through history) and
  `/activity.rss/` (latest 50): timestamp, user, patch, action.
- `/<cf>/reports/authorstats/` is the one page behind the community login
  (the `.env` archive credentials would work there; not needed otherwise).

Analytics this unlocks: review time and reviewer count per committed patch;
commitfests survived (moves) before commit; committed vs returned vs withdrawn
per commitfest and the queue size over a decade; reviewer / committer load and
its concentration; cfbot rebase churn and CI failure rates; the Bugfix-tagged
population (fixes that went through review, a different population from
pgsql-bugs); and whether AI-disclosed threads become patches, get committed,
and how fast, against the rest.

Plan (additive):
- `python/pg_analysis/commitfest_sync.py` with a `pg-cf-sync` console script
  (`[project.scripts]`; `refresh_data` calls its `main()` in-process, so fail
  by raising): pull the patches JSON for every commitfest id and the threads
  JSON per patch (~6,500 patches; polite pacing) into `data/raw/`
  `commitfest_patches.csv` (grain patch x commitfest) and
  `commitfest_patch_threads.csv` (grain patch x root message id). Read them
  through `sources/`, one raw model per file.
- Marts: `dim_patch` (surrogate key, name, authors, first/last commitfest,
  final status), `fct_patch_commitfests` (patch x commitfest, status), and a
  `bridge_patch_thread` to `fct_threads` by root message id; then a
  patch -> commit link through `discussion_refs`.
- Second step, once the JSON slice is in: scrape `/patch/<id>/` for tags,
  reviewers, committer, cfbot and the status history (same order of
  requests), giving the review-time and load measures.
- Boards: a commitfest page (throughput per CF, queue age, reviewer load) and
  an AI-vs-rest patch-outcome chart on `email_list_analysis`.

## Support strips whose cells run together (WARN-SUPPORT-TABLE-CELL-OVERFLOW)

Five per-release / per-quarter support strips print cells wider than their
category band, so neighbouring values touch (e.g. `fix_hardening_split`'s
"Hardening %" row reads "5.012.210.4"): `1_fix_analysis` `fix_cve_split`,
`fix_hardening_split` and `fix_origin_counts`, and `churn_by_quarter` on
`git_activity` and the article. Options per chart: a whole-percent or compact
format, a smaller strip font, fewer categories, or a wider card.

## Drop the remaining slot formats once dct reads query `formats:` everywhere

dct 0.10.0 applies a query's `formats:` to primary axes, hovers, tables and
KPI values, but not to `support_table` rows, a layer's own y axis (which
takes the BASE query's format instead), or a KPI `support:` line. Those slots
keep their own `format:` (the support strips on `1_fix_analysis`,
`bug_reports`, `git_activity` and the article; the dual-axis share layers;
`changelog`'s `percent_delta` KPI lines). Reported as dbt-charts #74; once a
release fixes it, delete those slot formats and let the queries carry them.

## Re-evaluate dbt 2.x (not urgent; revisit ~Dec 2026 – Jan 2027)

dbt 2.x is developed in `dbt-labs/dbt-core` itself (`main` is the Rust engine;
the `dbt-fusion` repo is archived). The project runs on dbt-core 1.12.x, which
bundles the 2.x parser (`dbt-core-experimental-parser`, 2.0.0-beta.2 in
1.12.6) behind `--use-v2-parser`. The project parses cleanly with it and both
parsers produce matching manifests, but nothing can build on 2.x yet.

**Blocker: Python models on DuckDB.** The 2.x engine fails every Python model
with "Python models are not supported for duckdb adapter", and 11 of the 70
models are Python (the whole `raw_git` / `raw_mail` layer and the three LLM
classifiers), so 69 of 70 models are blocked. Known and confirmed by dbt Labs
in dbt-core #14514 ("DuckDB bugbash: Python model parity", Apr 2026), but
unassigned, no milestone, and a Sept 2026 "still on the roadmap?" question is
unanswered. The docs list Python models in v2 for Snowflake, BigQuery and
Databricks only. Nothing else here is worth doing until #14514 moves.

Other 2.x issues that touch this project:
- dbt-core #16448: a unit test's `overrides.vars` hides the project's
  `vars.yml` vars (breaks the `int_releases` unit test). Fixed Oct 2026,
  awaiting release.
- dbt-core #16627: DuckDB source schema download ignores `external_location`,
  so `--static-analysis strict` turns static analysis off for everything
  downstream of the CSV sources (the sources themselves build fine).
- dbt-core #14512: the `external_location` parity check from the same DuckDB
  bugbash, still open.

Not yet reported upstream (`--use-v2-parser` handoff bugs in 1.12.6):
- A unit test whose `overrides` sets only `vars` is written with
  `"macros": null`, which dbt 1.12.6 rejects when loading the manifest.
  `int_releases.yml` declares `macros: {}` to work around it.
- `dbt.config.meta_get()` in a Python model returns nothing: the model's
  `meta_keys_used` doesn't survive the handoff, so the two AI-involvement
  models fail with the flag (2.x run directly compiles them correctly).
- The bundled beta rejects a source's top-level `meta:` (dbt1060); #14351
  fixed this for models and columns only. The sources use `config: meta:`.

To re-evaluate: upgrade to the newest 1.x and run
`dbt parse --use-v2-parser`, then `dbt build --use-v2-parser`; for 2.x itself,
install the current `dbt-core` 2.x release in a separate venv and build
against a COPY of `transform.duckdb` through a scratch `--profiles-dir` (the
on-run-end `drop_orphaned_relations` hook drops whatever that engine doesn't
see as a model, and the CSV hooks write into `data/`, so snapshot it first).
The 2.x binary also writes `.user.yml` into the repo root and appends
`dbt_internal_packages/` to `.gitignore`; revert those after a trial.
