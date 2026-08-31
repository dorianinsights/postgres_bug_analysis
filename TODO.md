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
