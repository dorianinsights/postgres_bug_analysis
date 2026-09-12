SELECT
  icv.ship_release_dt AS release_dt,
  igc.fix_key,
  MIN(igc.commit_dt) AS first_commit_dt,
  MAX(igc.commit_dt) AS last_commit_dt,
  COUNT(*) AS commit_cnt,
  -- a fix can land twice on one branch (a same-subject follow-up)
  COUNT(DISTINCT igc.branch) AS branch_cnt,
  BOOL_OR(org.documented_item_ord IS NOT null) AS is_documented,
  MIN(org.documented_item_ord) AS documented_item_ord,
  BOOL_OR(org.is_documented_security) AS is_security,
  BOOL_OR(org.origin = 'pgsql-bugs') AS from_bugs,
  BOOL_OR(org.origin = 'pgsql-hackers') AS from_hackers,
  {{ resolve_fix_origin('from_bugs', 'from_hackers', 'is_security') }} AS origin
FROM {{ ref('int_git_commits') }} AS igc
INNER JOIN {{ ref('int_commit_versions') }} AS icv ON igc.commit_hash = icv.commit_hash
LEFT OUTER JOIN {{ ref('int_commit_origins') }} AS org ON igc.commit_hash = org.commit_hash
-- the backpatch stream only: shipped in a minor, or pending for the open one
WHERE icv.release_status IN ('shipped', 'open') AND NOT igc.is_housekeeping
GROUP BY icv.ship_release_dt, igc.fix_key
