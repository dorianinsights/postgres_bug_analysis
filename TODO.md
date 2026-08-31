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

## Read the SGML release notes at build time (retire the last clone-derived raw CSVs)

`release_items.csv` and `item_commits.csv` are still produced by the standalone
`scrape_release_notes_sgml.py`, even though both are parsed straight out of the
clone (`git show REL_NN_STABLE:doc/src/sgml/release-NN.sgml`). They're the last
clone-derived data sitting in `data/raw/` — everything else git-side
(`raw_git_commits`, `raw_git_tags`, and now the release registry via
`int_releases`) reads the clone directly at build time.

**Proposed fix:** lift the DocBook parser into a shared `gitsource`-style module
and expose it through `models/raw_git/` **Python models** (mirroring
`raw_git_commits.py` / `raw_git_tags.py`), so `release_items` and `item_commits`
are parsed from the clone during `dbt build`. Benefits: one consistent clone
snapshot for the whole git side (no scraper-run drift), and `data/raw/` shrinks
to just `cve_severity.csv` — the only genuinely external source (scraped from
postgresql.org/support/security, not in the clone). Both models are a few
thousand rows, fine for a pyarrow build-time model.
