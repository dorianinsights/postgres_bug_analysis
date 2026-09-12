WITH coverage AS (
  SELECT
    group_ord,
    COUNT(DISTINCT abbrev_hash) AS annotated_commit_cnt,
    COUNT(DISTINCT abbrev_hash) FILTER (WHERE commit_hash IS NOT null) AS matched_commit_cnt
  FROM {{ ref('int_fix_commits') }}
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
  cov.annotated_commit_cnt,
  cov.matched_commit_cnt,
  prf.file_cnt,
  prf.lines_added_sum,
  prf.lines_deleted_sum,
  prf.has_test_changes,
  prf.is_docs_only,
  prf.dominant_subsystem
FROM {{ ref('int_fix_reps') }} AS reps
LEFT JOIN coverage AS cov ON reps.item_ord = cov.group_ord
LEFT JOIN rep_commit AS rpc ON reps.item_ord = rpc.group_ord
LEFT JOIN {{ ref('int_commit_profile') }} AS prf ON rpc.commit_hash = prf.commit_hash
