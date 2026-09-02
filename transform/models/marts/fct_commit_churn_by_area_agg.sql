-- Quarterly code churn by area, per file (int_commit_files) so a commit spanning
-- areas splits across them. Two branch_scopes from one grain:
--   trunk  -- master (development lifecycle), feature development, counted once
--   stable -- the released majors' stable branches, backpatch fixes, counted PER
--             branch (a fix on N majors is N commits) -- matches the churn charts'
--             long-standing "per branch" semantics
-- The in-progress major's beta branch (lifecycle 'beta') and the special members
-- are neither, so they drop out. This carries ALL churn -- plumbing included and
-- every file_class -- so the exclusions live downstream in the report, not baked
-- in here: is_plumbing rides along (a plumbing sweep such as a translation-catalog
-- refresh is mechanical, not development, and charts drop it by default) alongside
-- subsystem (directory) and file_class (extension). A chart holds the area
-- breakdown while filtering plumbing and the generated file_classes (translations,
-- test_fixtures) in or out. NOTE: translation churn lives almost entirely in
-- plumbing commits, so surfacing it means relaxing the plumbing filter, not just
-- the file_class one. Line counts are NULL for binary files, so binary churn is
-- excluded. UTC quarters. Grain = (quarter_dt, branch_scope, subsystem, file_class, is_plumbing).
SELECT
  DATE_TRUNC('quarter', fcm.commit_dt)::DATE AS quarter_dt,
  CASE WHEN dmj.lifecycle = 'development' THEN 'trunk' ELSE 'stable' END AS branch_scope,
  icf.subsystem,
  icf.file_class,
  fcm.is_plumbing,
  COUNT(DISTINCT fcm.commit_hash)::BIGINT AS commit_cnt,
  SUM(COALESCE(icf.lines_added, 0))::BIGINT AS lines_added_sum,
  SUM(COALESCE(icf.lines_deleted, 0))::BIGINT AS lines_deleted_sum,
  SUM(COALESCE(icf.lines_added, 0) + COALESCE(icf.lines_deleted, 0))::BIGINT AS churn
FROM {{ ref('int_commit_files') }} AS icf
INNER JOIN {{ ref('fct_commits') }} AS fcm ON icf.commit_hash = fcm.commit_hash
INNER JOIN {{ ref('dim_major') }} AS dmj ON fcm.dim_major_key = dmj.dim_major_key
WHERE dmj.is_released OR dmj.lifecycle = 'development'
GROUP BY ALL
