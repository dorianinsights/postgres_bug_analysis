SELECT
  dmj.dim_major_key,
  bsw.week_start,
  bsw.subsystem,
  bsw.file_class,
  bsw.commit_hash,
  bsw.code_lines,
  bsw.file_cnt
FROM {{ ref('stg_branch_size_weekly') }} AS bsw
INNER JOIN {{ ref('dim_major') }} AS dmj ON bsw.branch = dmj.stable_branch
-- a branch is frozen after its final minor; the weeks past it are not a curve
WHERE bsw.week_start <= dmj.eol_dt
