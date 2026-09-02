# TODO — outstanding work

Work still remaining for this repo. See `CLAUDE.md` for standing
conventions/gotchas and `README.md` for architecture. Keep this file to open
items only: when something ships, delete its section rather than annotating it.

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
(`sources.git.commit_range`; `int_backpatch_fixes` excludes the in-progress
branch; `fct_major_development` folds its commits into the major's development
count). No model labels an individual beta-branch commit, and `fct_fixes` never
sees them (fixes to unreleased code are not documented in any minor notes).

Plan (additive; no change to `fct_fixes` or the projections):
- `intermediate/int_beta_commit_classes.sql` (or a column on `dim_commit`),
  grain `(branch, commit_hash)` for the `dev_status <> 'released'` branch, with
  `commit_class` in {`backport`, `beta_stabilization`, `housekeeping`} from three
  signals, in precedence:
  1. Normalized-subject twin on a released stable branch (the
     `int_backpatch_fixes` `fix_key` rule — exact string, so a reworded subject
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
- **git:** history below `GIT_HISTORY_SINCE` is immutable. Cache per-branch
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

## dbt-charts (dct) `{{ ref() }}` doesn't resolve in the render path (v0.5.0)

Faces use bare table names + the `duckdb` `warehouse` source because `dct
render` / `dct serve` throw `ERR-JINJA-ERROR: 'ref' is undefined` on
`{{ ref('model') }}`: the render pipeline runs the variable Jinja pass
(StrictUndefined) over the raw SQL *before* ref resolution. `dct query` resolves
refs fine on both the `warehouse` and `metrics` sources, so it is purely the
render-path ordering. 0.5.0 is the latest release on PyPI.

Revisit when a dct release resolves refs before the variable pass, then migrate
the faces from bare table names to `{{ ref() }}`. Until then keep bare table
names for SQL boards.

## Upcoming release on the changelog "Fixes per Scheduled Minor Release" chart

The chart plots documented changelog `item_cnt` for shipped releases only, so
the upcoming (open) release is absent from the lines. The KPI tiles already show
its committed "fixes so far" (`early_fix_cnt`), but the committed distinct-fix
count runs ~1.5–2.6x the eventual documented `item_cnt` per major, so dropping
it onto the same lines would plot the upcoming release ~2x too tall.

Decide + implement one of:
1. Feather (dashed) a per-major COMMITTED-fixes-so-far point at the open
   release, labeled as a commit-scale leading indicator (~2x documented).
2. Feather a per-major PROJECTED documented-item count from the projection
   models — same scale as the lines, but a forecast rather than the live count.
3. A dedicated small "upcoming release: fixes committed so far, per major" chart
   on the commit measure, separate from the item-count lines.
