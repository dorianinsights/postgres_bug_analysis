-- Monthly master-branch development activity split by origin: how much
-- work traces to filed bug reports vs hackers-list threads vs no public
-- trail — the latter split into embargoed security work (the commit
-- belongs to a security-category release-note fix) and the genuinely
-- unsourceable. Master only — a backpatch is the same work under another
-- hash, so counting every branch would multiply each fix by its
-- backpatch breadth. UTC months.
WITH security_fix_commits AS (
  SELECT DISTINCT fcm.abbrev_hash
  FROM {{ ref('int_fix_commits') }} AS fcm
  INNER JOIN {{ ref('int_fix_reps') }} AS reps ON fcm.group_ord = reps.item_ord
  WHERE reps.category IN ('Security (CVE)', 'Security hardening (no CVE)')
),

master_commits AS (
  SELECT
    DATE_TRUNC('month', fcm.commit_dt)::DATE AS month_dt,
    CASE
      WHEN fcm.origin != 'unknown_or_internal' THEN fcm.origin
      WHEN sfc.abbrev_hash IS NOT null THEN 'unknown_or_internal_security'
      ELSE 'unknown_or_internal_not_security'
    END AS origin,
    fcm.is_plumbing,
    fcm.ai_credit
  FROM {{ ref('fct_commits') }} AS fcm
  LEFT JOIN security_fix_commits AS sfc ON LEFT(fcm.commit_hash, 9) = sfc.abbrev_hash
  WHERE fcm.branch = 'master'
),

commit_rollup AS (
  SELECT
    month_dt,
    origin,
    COUNT(*) FILTER (WHERE NOT is_plumbing) AS commit_cnt,
    COUNT(*) FILTER (WHERE ai_credit IS NOT null) AS ai_commit_cnt
  FROM master_commits
  GROUP BY ALL
),

thread_rollup AS (
  -- a cited thread is public by definition, so an unresolved one (older
  -- than the archive floor, or an uningested list) is never embargoed
  -- security — it lands in _not_security
  SELECT
    DATE_TRUNC('month', gcm.commit_dt)::DATE AS month_dt,
    COALESCE(ths.source_list, 'unknown_or_internal_not_security') AS origin,
    COUNT(DISTINCT dsc.message_id) AS cited_thread_cnt
  FROM {{ ref('int_commit_discussions') }} AS dsc
  INNER JOIN {{ ref('stg_git_commits') }} AS gcm
    ON dsc.commit_hash = gcm.commit_hash AND gcm.branch = 'master'
  LEFT JOIN {{ ref('int_thread_sources') }} AS ths ON dsc.message_id = ths.message_id
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
