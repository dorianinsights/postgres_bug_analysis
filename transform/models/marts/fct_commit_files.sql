-- Atomic churn fact: one row per file touched by one commit -- the lowest grain
-- of the git change stream, the file-level detail behind the commit-grain
-- fct_commits. Every churn metric (by area, by file type, by branch scope, at any
-- time interval) rolls up from here dynamically, so no metric needs its own
-- pre-aggregated table; a MetricFlow semantic model (fct_commit_files_semantic)
-- exposes the same measures at arbitrary time grains. Conforms to dim_major on
-- dim_major_key and to dim_date on commit_dt; subsystem, file_class, is_plumbing
-- and branch_scope ride along as degenerate dimensions (from int_commit_files +
-- the commit's row). Line counts are NULL for binary files (git numstat '-'), so
-- SUMs naturally exclude binary churn. branch_scope folds the commit's major
-- lifecycle into the churn view: trunk (master), stable (released backpatch
-- stream), beta (in-progress major). Grain = (commit_hash, file_path).
SELECT
  fcm.dim_major_key,
  fcm.commit_dt,
  fcm.commit_hash,
  icf.file_path,
  CASE dmj.lifecycle
    WHEN 'development' THEN 'trunk'
    WHEN 'released' THEN 'stable'
    WHEN 'beta' THEN 'beta'
    ELSE 'other'
  END AS branch_scope,
  fcm.is_plumbing,
  icf.subsystem,
  icf.file_class,
  icf.lines_added,
  icf.lines_deleted
FROM {{ ref('int_commit_files') }} AS icf
INNER JOIN {{ ref('fct_commits') }} AS fcm ON icf.commit_hash = fcm.commit_hash
INNER JOIN {{ ref('dim_major') }} AS dmj ON fcm.dim_major_key = dmj.dim_major_key
