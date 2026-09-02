-- Quarterly code churn by area, per file (int_commit_files) so a commit spanning
-- areas splits across them. Two branch_scopes from one grain:
--   trunk  -- master (development lifecycle), feature development, counted once
--   stable -- the released majors' stable branches, backpatch fixes, counted PER
--             branch (a fix on N majors is N commits) -- matches the churn charts'
--             long-standing "per branch" semantics
-- The in-progress major's beta branch (lifecycle 'beta') and the special members
-- are neither, so they drop out. Non-plumbing only (a plumbing sweep -- e.g. a
-- translation-catalog refresh -- is not development). subsystem (directory) and
-- file_class (extension) both ride along, so a chart can hold the area breakdown
-- while filtering the generated file classes (translations, test_fixtures) in or
-- out of a line count. Line counts are NULL for binary files, so binary churn is
-- excluded. UTC quarters. Grain = (quarter_dt, branch_scope, subsystem, file_class).
SELECT
  DATE_TRUNC('quarter', fcm.commit_dt)::DATE AS quarter_dt,
  CASE WHEN dmj.lifecycle = 'development' THEN 'trunk' ELSE 'stable' END AS branch_scope,
  icf.subsystem,
  icf.file_class,
  COUNT(DISTINCT fcm.commit_hash)::BIGINT AS commit_cnt,
  SUM(COALESCE(icf.lines_added, 0))::BIGINT AS lines_added_sum,
  SUM(COALESCE(icf.lines_deleted, 0))::BIGINT AS lines_deleted_sum,
  SUM(COALESCE(icf.lines_added, 0) + COALESCE(icf.lines_deleted, 0))::BIGINT AS churn
FROM {{ ref('int_commit_files') }} AS icf
INNER JOIN {{ ref('fct_commits') }} AS fcm ON icf.commit_hash = fcm.commit_hash
INNER JOIN {{ ref('dim_major') }} AS dmj ON fcm.dim_major_key = dmj.dim_major_key
WHERE NOT fcm.is_plumbing AND (dmj.is_released OR dmj.lifecycle = 'development')
GROUP BY ALL
