-- Quarterly code churn on the development trunk (master), attributed to each
-- FILE's subsystem -- the area breakdown of trunk feature development over time.
-- Per file (int_commit_files), so a commit spanning subsystems splits across them
-- (unlike fct_commits.dominant_subsystem, one area per commit). Master only + non-
-- plumbing: a backpatch is the same work under another hash, so counting every
-- stable branch would multiply it -- the released-branch backpatch churn is the
-- separate churn_by_quarter chart. Line counts are NULL for binary files, so
-- binary churn is excluded. UTC quarters. Grain = (quarter_dt, subsystem).
SELECT
  DATE_TRUNC('quarter', fcm.commit_dt)::DATE AS quarter_dt,
  icf.subsystem,
  COUNT(DISTINCT fcm.commit_hash)::BIGINT AS commit_cnt,
  SUM(COALESCE(icf.lines_added, 0))::BIGINT AS lines_added_sum,
  SUM(COALESCE(icf.lines_deleted, 0))::BIGINT AS lines_deleted_sum,
  SUM(COALESCE(icf.lines_added, 0) + COALESCE(icf.lines_deleted, 0))::BIGINT AS churn
FROM {{ ref('int_commit_files') }} AS icf
INNER JOIN {{ ref('fct_commits') }} AS fcm ON icf.commit_hash = fcm.commit_hash
INNER JOIN {{ ref('dim_major') }} AS dmj ON fcm.dim_major_key = dmj.dim_major_key
WHERE dmj.lifecycle = 'development' AND NOT fcm.is_plumbing
GROUP BY ALL
