WITH stable_commits AS (
  SELECT
    igc.branch,
    igc.commit_hash,
    igc.commit_dt,
    igc.fix_key,
    icv.ship_release_dt AS release_dt
  FROM {{ ref('int_git_commits') }} AS igc
  INNER JOIN {{ ref('int_commit_versions') }} AS icv ON igc.commit_hash = icv.commit_hash
  -- the backpatch stream only: shipped in a minor, or pending for the open one
  -- (a major's pre-GA 'development' commits are not minor-release fixes)
  WHERE icv.release_status IN ('shipped', 'open') AND NOT igc.is_housekeeping
),

-- the release-notes item citing each commit: the lowest item when a combined
-- commit is annotated under several, security if any of them cites a CVE
documented AS (
  SELECT
    fcm.commit_hash,
    MIN(fcm.group_ord) AS documented_item_ord,
    BOOL_OR(reps.cves IS NOT null) AS is_security_item
  FROM {{ ref('int_fix_commits') }} AS fcm
  INNER JOIN {{ ref('int_fix_reps') }} AS reps ON fcm.group_ord = reps.item_ord
  WHERE fcm.commit_hash IS NOT null
  GROUP BY ALL
),

rollup AS (
  SELECT
    stc.release_dt,
    stc.fix_key,
    MIN(stc.commit_dt) AS first_commit_dt,
    MAX(stc.commit_dt) AS last_commit_dt,
    COUNT(*) AS commit_cnt,
    -- a fix can land twice on one branch (a same-subject follow-up)
    COUNT(DISTINCT stc.branch) AS branch_cnt,
    BOOL_OR(org.origin = 'pgsql-bugs') AS from_bugs,
    BOOL_OR(org.origin = 'pgsql-hackers') AS from_hackers,
    BOOL_OR(dfx.documented_item_ord IS NOT null) AS is_documented,
    MIN(dfx.documented_item_ord) AS documented_item_ord,
    COALESCE(BOOL_OR(dfx.is_security_item), false) AS is_security
  FROM stable_commits AS stc
  LEFT OUTER JOIN {{ ref('int_commit_origins') }} AS org ON stc.commit_hash = org.commit_hash
  LEFT OUTER JOIN documented AS dfx ON stc.commit_hash = dfx.commit_hash
  GROUP BY ALL
)

SELECT
  release_dt,
  fix_key,
  first_commit_dt,
  last_commit_dt,
  commit_cnt,
  branch_cnt,
  is_documented,
  documented_item_ord,
  is_security,
  {{ resolve_fix_origin('from_bugs', 'from_hackers', 'is_security') }} AS origin
FROM rollup
