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
the open one's so-far bar (a dashed-outline bar layer; note dct turns an
explicit `sort:` on a layered chart into an alphabetical axis, so the query's
ORDER BY orders the axis). Follow that here: keep this chart documented-only and add a per-major
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

## Next AI-involvement prompt bump (`AI_PROMPT_VERSION`)
A version bump re-infers all ~32k texts (~17 h), so batch these into one:
- Add `clang-tidy` (and linters generally) to the prompt's list of non-AI tools --
  the Sept 2026 scan flagged four "harmonize parameter names" commits as
  AI-authored because "written with help from clang-tidy".
- Drop `machine learning` from `HINT_NET` -- it only pulled in pre-LLM ML
  mentions (a 2020 planner-forecasting thread). Anything before late 2022 cannot
  be an LLM disclosure.
- Teach it that a vendor's AI security platform credited in Reported-by
  ("Xint Code") is AI-found with vendor `other` (the review ruled this; the
  model was inconsistent).
Until then the review seed (`ai_involvement_reviews`) carries the corrections.
