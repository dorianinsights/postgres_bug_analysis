WITH commit_rollup AS (
  SELECT
    fcm.group_ord,
    COUNT(*) AS annotated_commit_cnt,
    COUNT(fcm.commit_hash) AS matched_commit_cnt,
    BOOL_OR(org.origin = 'pgsql-bugs') AS from_bugs,
    BOOL_OR(org.origin = 'pgsql-hackers') AS from_hackers
  FROM {{ ref('int_fix_commits') }} AS fcm
  LEFT OUTER JOIN {{ ref('int_commit_origins') }} AS org ON fcm.commit_hash = org.commit_hash
  GROUP BY ALL
),

-- the annotated commit on master when there is one, else the newest match
rep_commit AS (
  SELECT
    group_ord,
    commit_hash
  FROM {{ ref('int_fix_commits') }}
  WHERE commit_hash IS NOT null
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY group_ord
    ORDER BY (branch = 'master') DESC, commit_ts DESC, commit_hash ASC
  ) = 1
)

SELECT
  reps.item_ord,
  reps.release_dt,
  reps.version,
  reps.item_index,
  cmr.annotated_commit_cnt,
  cmr.matched_commit_cnt,
  prf.file_cnt,
  prf.lines_added_sum,
  prf.lines_deleted_sum,
  prf.has_test_changes,
  prf.is_docs_only,
  prf.dominant_subsystem,
  {{ resolve_fix_origin(
    'COALESCE(cmr.from_bugs, false)', 'COALESCE(cmr.from_hackers, false)', 'reps.cves IS NOT null'
  ) }} AS origin
FROM {{ ref('int_fix_reps') }} AS reps
LEFT OUTER JOIN commit_rollup AS cmr ON reps.item_ord = cmr.group_ord
LEFT OUTER JOIN rep_commit AS rpc ON reps.item_ord = rpc.group_ord
LEFT OUTER JOIN {{ ref('int_commit_profile') }} AS prf ON rpc.commit_hash = prf.commit_hash
