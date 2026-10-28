{{ config(severity='warn') }}

-- The model's vendor and its flags should agree: vendor 'none' exactly when no
-- flag is set. The raw answer is kept as is (the cache is a faithful record),
-- and neither kind of contradiction counts as AI involvement downstream, so a
-- few are harmless noise. Warn only when a population's share of contradictory
-- answers passes var('ai_involvement_contradiction_alarm_share'): the sign of a
-- model or prompt change gone bad, not a list of rows to review.
WITH answers AS (
  SELECT
    'commit' AS population,
    (vendor = 'none') != NOT (ai_found OR ai_analyzed OR ai_authored OR ai_tooling OR mentioned_only)
      AS is_contradiction
  FROM {{ ref('int_commit_ai_involvement') }}
  WHERE is_classified
  UNION ALL
  SELECT
    'thread' AS population,
    (vendor = 'none') != NOT (ai_found OR ai_analyzed OR ai_authored OR ai_tooling OR mentioned_only)
      AS is_contradiction
  FROM {{ ref('int_thread_ai_involvement') }}
  WHERE is_classified
),

shares AS (
  SELECT
    population,
    COUNT(*) AS classified_cnt,
    COUNT(*) FILTER (WHERE is_contradiction) AS contradiction_cnt
  FROM answers
  GROUP BY ALL
)

SELECT
  population,
  classified_cnt,
  contradiction_cnt,
  contradiction_cnt / classified_cnt AS contradiction_pct
FROM shares
WHERE contradiction_cnt / classified_cnt > {{ var('ai_involvement_contradiction_alarm_share') }}
