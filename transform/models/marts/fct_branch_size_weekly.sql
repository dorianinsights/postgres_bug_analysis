-- Weekly periodic-snapshot fact: the STATE (size) of each stable branch's tree at
-- weekly intervals -- a STOCK, conforming to dim_date on week_start and to
-- dim_major on dim_major_key (the branch/major line -- its label, stable branch,
-- and support window live there). Distinct from the codebase's exact size AT a
-- release tag (the retired fct_version_size_agg): this is size over CALENDAR time
-- -- the growth curve. code_lines is the total across the source globs;
-- doc_lines/test_lines are the .sgml and src/test subsets (so implementation
-- lines = code_lines - doc_lines - test_lines). A per-major stock, NEVER summed
-- across majors (parallel copies of one tree). FLOW (churn, commit counts) is
-- deliberately NOT here -- that lives in fct_commits, joined on the same grain.
-- commit_hash is the exact tree measured (the branch HEAD as of the week's end):
-- a provenance pointer, not an aggregation key. Grain = (dim_major_key,
-- week_start). -> ../data/derived/fct_branch_size_weekly.csv
SELECT
  dmj.dim_major_key,
  bsw.week_start,
  bsw.commit_hash,
  bsw.code_lines,
  bsw.doc_lines,
  bsw.test_lines,
  bsw.file_cnt
FROM {{ ref('stg_branch_size_weekly') }} AS bsw
INNER JOIN {{ ref('dim_major') }} AS dmj ON bsw.branch = dmj.stable_branch
