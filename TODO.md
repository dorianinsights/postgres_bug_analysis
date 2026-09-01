# TODO — outstanding work

Known issues and future work for this repo. See `CLAUDE.md` for standing
conventions/gotchas and `README.md` for architecture.

## Capture fix `Reported-by:` credits (`bridge_fix_reporter`)

`fct_fixes` drops the `Reported-by:` commit trailers entirely. It only links a
fix to a reporter via `primary_bug_number` (→ `dim_bug`), which is populated
only when there's a public `BUG #NNNNN` form. Security fixes never have that —
they come in embargoed to security@ and credit researchers solely through
`Reported-by:` trailers — so for every CVE fix the entire reporter list is
lost. It's not an edge case: **263 corpus fixes carry more than one
`Reported-by:` trailer** (e.g. commit `4fafe2380` / CVE-2026-14669 credits 11).

Note this is *not* a `dim_bug` problem: a `BUG #` web-form report has exactly
one filer (`Logged by:` / `Email address:`), so `dim_bug.reporter_person_key`
is correct as one-per-bug. The gap is a missing fix→reporter many-to-many.

**Proposed fix** (additive, mirrors `bridge_fix_cve` / `bridge_fix_bug`):
- `intermediate/int_fix_reporters.sql` — parse `Reported-by:` trailers from a
  fix's commits (grain `(item_ord, reporter_name, reporter_email)`).
- `marts/bridge_fix_reporter.sql` — grain `(item_ord, person_key)`, each
  reporter resolved through `int_person_map` → `dim_person`. FKs → `fct_fixes`,
  `dim_person`.
- optionally denormalize `reporter_cnt` onto `fct_fixes`.
- tests: `unique_combination_of_columns` on the pair; `relationships` from each
  side to its dim and to `fct_fixes`.

## Extend the corpus to PG 19 when it GAs (~Sept/Oct 2026)

PG 19 is in beta (`REL_19_BETA1/2/3`, `REL_19_STABLE` branched, no `REL_19_0`
yet). Don't include it until GA: the pipeline assumes each corpus major has
shipped its `.0` — `sources.git.branch_range('REL_19_STABLE')` is
`REL_19_0..REL_19_STABLE`, which errors (`unknown revision`) until `REL_19_0`
exists, and there are no minor-release fix waves to analyze during beta anyway.

At GA it's essentially a **one-line, reviewed change**: `LAST_MAJOR = 19` in
`corpus.py`. Much already anticipates it — `stg_git_tags` scans `REL_1[5-9]_*`
and filters prereleases out, so `REL_19_0` flows into `int_releases`
automatically; `branch_range` resolves; and the open-release version projection
(`active_majors` = `MAX(minor)+1`) picks up `19.1` the moment `REL_19_0` is
tagged. Tags never rename: `REL_19_BETAn`/`REL_19_RC1` are permanent, GA adds a
separate `REL_19_0`.

Separate, larger option (NOT a corpus bump): track **19 beta development
activity** now — would need `branch_range` special-cased for an unreleased major
(range from the branch point or `REL_19_BETA1` instead of `REL_19_0`), living
outside the minor-wave models.

## Parquet-cache the immutable raw parses (mbox + git)

`raw_list_messages` (mbox) and `raw_commit_files` (git) re-parse the entire
history on every build. They're now parallelized across a process `Pool`
(`sources/mail.py` ~257s→~43s, ~6x; `sources/git.py` ~33s→~25s — the git side is
bounded by `master`, the one branch a per-branch fan-out can't split), but the
work is still redone every run.

The bigger lever is to **cache the immutable parses as Parquet and only re-parse
what changed** — the highest-payoff win for repeated builds, on top of the
parallelization:
- **mbox:** monthly files at `.cache/mbox/<list>/YYYYMM.mbox` are immutable once
  a month is past (the sync only re-fetches the current month). Parse each month
  once to `.cache/mbox_parsed/<list>/YYYYMM.parquet` (skip when the parquet is
  newer than its mbox); re-parse only the current month. Rebuilds then read the
  rest straight from Parquet (DuckDB reads it natively/fast) → the mail side
  drops to ~seconds.
- **git:** history below `GIT_HISTORY_SINCE` is immutable; only recent commits
  are added. Cache per-branch numstat/log parses keyed by the branch tip SHA
  (or an incremental `dbt` materialization), re-parsing only the new commits
  since the cached tip.

Both keep byte-identical output (parse-once, read-back). Consider making
`raw_list_messages` / `raw_commit_files` incremental `dbt` models, or doing the
mtime/SHA-keyed caching inside `sources/mail.py` / `sources/git.py`.

## Coerce naive email `Date` timestamps to UTC in `sources/mail.py`

A `-0000` `Date` header (RFC 5322: "UTC, but local zone unknown") makes Python's
`email.utils.parsedate_to_datetime` return a *naive* datetime, so `_sent_ts`'s
`.isoformat()` emits no offset and `stg_list_messages.sent_ts::TIMESTAMPTZ`
falls back to the **build machine's session timezone**. That value is then both
wrong (read as HST instead of UTC on Josh's machine) and **non-deterministic**
across build environments — a CI build in UTC would store a different instant.

Currently exactly **1 of 159,714** messages hits this
(`<7f6fabaa-3f8f-49ab-89ca-59fbfe633105@me.com>`, renans.l@icloud.com,
2022-02-18; its `sent_dt` lands on 2022-02-19 instead of 2022-02-18).
Negligible for aggregates, but a latent correctness + reproducibility defect
that spreads silently if more `-0000` senders appear. Audited 2026-08-31; the
other timestamped raw sources (`raw_git_commits`/`%cI`, `raw_git_tags`/iso-strict,
`raw_item_commits` via `STRPTIME %z`) all preserve their offset correctly.

Fix (one place, the reader) — default a naive parse to UTC:

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

Rebuilds change exactly that one row (`sent_ts` gains `+00:00`, `sent_dt`
2022-02-19 → 2022-02-18), rippling into `fct_messages` and possibly a ±1 in a
message-day count — all corrections.

## dbt-charts (dct) `{{ ref() }}` doesn't resolve in the render path (v0.5.0)

We wanted faces to reference models via `{{ ref('model') }}` instead of bare
table names + the `duckdb` search-path source. It half-works and is NOT usable
for boards today:

- With a `dbt_profile` source (`type: dbt_profile`, `profile`, `target`),
  `dct query warehouse "… {{ ref('fct_fixes') }} …"` **resolves** (returns rows;
  a bare `fct_fixes` fails because dbt_profile sets no search path).
- But `dct render` / `dct serve` — the actual dashboard path — throws
  `ERR-JINJA-ERROR: 'ref' is undefined`. The render pipeline runs the variable
  Jinja pass (StrictUndefined) over the raw SQL *before* ref resolution, so
  `{{ ref() }}` trips it. Same source config, same manifest, same cwd — only the
  code path differs (`dct query` resolves first; `dct render` doesn't).

v0.5.0 is the latest on PyPI (only 0.0.1 and 0.5.0 exist), so no upgrade fixes
it. Verified 2026-08-31. Revisit when a dct release resolves refs in the render
path (the fix is ordering ref-resolution before the variable pass). Until then,
keep bare table names + the `duckdb` source for SQL boards (renders fine).

Note: `dbt_charts.yml` + `faces/` now live under `transform/` (beside
`dbt_project.yml`), so the dbt manifest + semantic layer resolve natively -- but
that alone does NOT fix the render-path `ref()` bug above (it's the Jinja
ordering, independent of layout). The co-location DID enable `type: metricflow`
boards, which render correctly (a `dbt_profile` `metrics` source is configured);
see the MetricFlow proof below.

## MetricFlow foundation (proven; charts not yet migrated)

Non-additive ratios (shares, rates) can't be re-aggregated from a stored
per-grain value -- `AVG(monthly shares) != SUM(num)/SUM(denom)`. MetricFlow
solves this by computing the ratio at query grain from additive measures, and
it runs fully locally on DuckDB (no dbt Cloud, no hosting).

Proven 2026-08-31: one semantic model over the atomic `fct_messages` grain
(`models/marts/list_traffic_semantic.yml`) reproduces BOTH materialized traffic
aggs EXACTLY -- month vs `fct_list_traffic_monthly_agg` 118/118 rows 0 mismatch,
week vs `fct_list_traffic_weekly_agg` 514/514 rows 0 mismatch -- and gives any
other grain (day/quarter/year) for free, with `fix_linked_share` correct at each
grain (pooled 0.4777 vs the wrong avg-of-monthly-shares 0.4347). It renders in
dct via a `type: metricflow` query against the `metrics` (`dbt_profile`) source.

Foundation committed: the `metrics` source in `dbt_charts.yml`, the `dim_date`
time-spine config, and the semantic model. dct's render uses the bundled
`metricflow` lib -- no `dbt-metricflow` needed (install `dbt-metricflow[duckdb]`
only if you want the `mf query` CLI for debugging).

Next (optional migration): repoint the ~6 traffic charts in `faces/origins.yml`
to `type: metricflow` queries and retire `fct_list_traffic_monthly_agg` +
`_weekly_agg` (and their CSVs). Gotchas: dimensions are referenced by entity
(`message__list_name`), time via `metric_time__<grain>`; a `type: metricflow`
query needs the `dbt_profile` source, not `duckdb`.
