SELECT
  dmj.dim_major_key,
  bwh.week_start,
  tsz.subsystem,
  tsz.file_class,
  bwh.commit_hash,
  tsz.code_lines,
  tsz.file_cnt
-- each week's head, and the size of the tree at it (quiet weeks share a head,
-- so a tree is measured once however many weeks it spans)
FROM {{ ref('int_branch_week_heads') }} AS bwh
INNER JOIN {{ ref('stg_tree_sizes') }} AS tsz ON bwh.commit_hash = tsz.commit_hash
INNER JOIN {{ ref('dim_major') }} AS dmj ON bwh.branch = dmj.stable_branch
-- a branch is frozen after its final minor; the weeks past it are not a curve
WHERE bwh.week_start <= dmj.eol_dt
