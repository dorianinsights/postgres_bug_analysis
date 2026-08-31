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
shipped its `.0` — `gitsource.branch_range('REL_19_STABLE')` is
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
