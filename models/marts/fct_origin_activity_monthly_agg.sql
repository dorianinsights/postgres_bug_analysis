WITH master_commits AS (
  SELECT
    DATE_TRUNC('month', fcm.commit_dt)::DATE AS month_dt,
    -- no public trail splits into embargoed security work and the unsourceable
    CASE
      WHEN fcm.origin != 'unknown_or_internal' THEN fcm.origin
      WHEN fcm.is_documented_security THEN 'unknown_or_internal_security'
      ELSE 'unknown_or_internal_not_security'
    END AS origin,
    fcm.has_ai_involvement
  FROM {{ ref('dim_commit') }} AS fcm
  INNER JOIN {{ ref('dim_major') }} AS dmj ON fcm.dim_major_key = dmj.dim_major_key
  -- master (the development trunk) only. NOT is_released is no longer a proxy for
  -- this: the in-progress major's stable branch (e.g. PG19 beta) is also
  -- unreleased, but its commits are backpatch-style stabilization, not trunk
  -- development. lifecycle = 'development' is master alone.
  WHERE dmj.lifecycle = 'development'
),

commit_rollup AS (
  SELECT
    month_dt,
    origin,
    COUNT(*) AS commit_cnt,
    COUNT(*) FILTER (WHERE has_ai_involvement) AS ai_commit_cnt
  FROM master_commits
  GROUP BY ALL
),

thread_rollup AS (
  -- a cited thread is public by definition, so an unresolved one (older
  -- than the archive floor, or an uningested list) is never embargoed
  -- security — it lands in _not_security
  SELECT
    DATE_TRUNC('month', gcm.commit_dt)::DATE AS month_dt,
    COALESCE(dsc.source_list, 'unknown_or_internal_not_security') AS origin,
    COUNT(DISTINCT dsc.message_id) AS cited_thread_cnt
  FROM {{ ref('int_commit_discussions') }} AS dsc
  INNER JOIN {{ ref('int_git_commits') }} AS gcm
    ON dsc.commit_hash = gcm.commit_hash AND gcm.branch = 'master'
  GROUP BY ALL
)

SELECT
  COALESCE(cro.month_dt, tro.month_dt) AS month_dt,
  COALESCE(cro.origin, tro.origin) AS origin,
  COALESCE(cro.commit_cnt, 0) AS commit_cnt,
  COALESCE(cro.ai_commit_cnt, 0) AS ai_commit_cnt,
  COALESCE(tro.cited_thread_cnt, 0) AS cited_thread_cnt
FROM commit_rollup AS cro
FULL OUTER JOIN thread_rollup AS tro
  ON cro.month_dt = tro.month_dt AND cro.origin = tro.origin
