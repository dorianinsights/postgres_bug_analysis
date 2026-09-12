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

commit_facts AS (
  SELECT
    stc.release_dt,
    stc.fix_key,
    stc.branch,
    stc.commit_hash,
    stc.commit_dt,
    org.origin,
    fcm.group_ord AS documented_item_ord,
    reps.cves IS NOT null AS is_security_item
  FROM stable_commits AS stc
  LEFT OUTER JOIN {{ ref('int_commit_origins') }} AS org ON stc.commit_hash = org.commit_hash
  LEFT OUTER JOIN {{ ref('int_fix_commits') }} AS fcm ON stc.commit_hash = fcm.commit_hash
  LEFT OUTER JOIN {{ ref('int_fix_reps') }} AS reps ON fcm.group_ord = reps.item_ord
),

rollup AS (
  SELECT
    release_dt,
    fix_key,
    MIN(commit_dt) AS first_commit_dt,
    MAX(commit_dt) AS last_commit_dt,
    -- DISTINCT: a commit annotated under two items appears twice in commit_facts
    COUNT(DISTINCT commit_hash) AS commit_cnt,
    COUNT(DISTINCT branch) AS branch_cnt,
    BOOL_OR(origin = 'pgsql-bugs') AS from_bugs,
    BOOL_OR(origin = 'pgsql-hackers') AS from_hackers,
    BOOL_OR(documented_item_ord IS NOT null) AS is_documented,
    -- the lowest item when a combined commit is annotated under several
    MIN(documented_item_ord) AS documented_item_ord,
    BOOL_OR(is_security_item) AS is_security
  FROM commit_facts
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
