-- Weekly periodic-snapshot fact: the STATE (size) of each stable branch's tree at
-- weekly intervals, SPLIT BY SUBSYSTEM -- a STOCK, conforming to dim_date on
-- week_start and to dim_major on dim_major_key (the branch/major line). Each row
-- is one subsystem's slice of one branch's tree that week; the subsystems of a
-- (branch, week) sum to its total size, so a total curve is SUM(code_lines) and a
-- composition chart reads the subsystems directly. subsystem is the shared
-- subsystem_rules taxonomy (same as int_fix_changes / fct_fixes). Distinct from
-- the codebase's exact size AT a release tag (the retired fct_version_size_agg):
-- this is size over CALENDAR time -- the growth curve. A per-major stock, NEVER
-- summed across majors (parallel copies of one tree). FLOW (churn, commit counts)
-- lives in fct_commits, joined on the same grain. commit_hash is the exact tree
-- measured (the branch HEAD as of the week's end): a provenance pointer, not an
-- aggregation key. Grain = (dim_major_key, week_start, subsystem).
SELECT
  dmj.dim_major_key,
  bsw.week_start,
  bsw.subsystem,
  bsw.commit_hash,
  bsw.code_lines,
  bsw.file_cnt
FROM {{ ref('stg_branch_size_weekly') }} AS bsw
INNER JOIN {{ ref('dim_major') }} AS dmj ON bsw.branch = dmj.stable_branch
