-- Simple linear estimates for the upcoming minor's fix count: the
-- current cycle's three early signals scaled by each signal's historical
-- median shipped-per-early ratio (medians over fix_projection_cycles,
-- which replays every closed cycle at today's cycle age), plus an
-- equal-weight blend. Deliberately naive — the point is a transparent,
-- explainable band, not a fitted model. The demand-side estimators
-- (reports, messages) assume the historical signal->fix conversion; the
-- supply-side estimator (committed pace) is what caught the Aug 2026
-- surge, where fixes grew without proportional inbound reports.
WITH wrap AS (
  SELECT MAX(wrap_dt) AS wrap_dt
  FROM {{ ref('int_release_calendar') }}
  WHERE wrap_dt <= CURRENT_DATE
),

ships AS (
  SELECT MIN(scheduled_release_dt) AS ships_at_dt
  FROM {{ ref('int_release_calendar') }}
  WHERE scheduled_release_dt > CURRENT_DATE
),

ratios AS (
  SELECT
    MEDIAN(shipped_fix_cnt * 1.0 / early_report_cnt) AS per_report,
    MEDIAN(shipped_fix_cnt * 1.0 / early_message_cnt) AS per_message,
    MEDIAN(shipped_fix_cnt * 1.0 / early_fix_cnt) AS per_early_fix
  FROM {{ ref('fix_projection_cycles') }}
),

current_signals AS (
  SELECT
    (
      SELECT COUNT(*) FROM {{ ref('int_bug_reports') }} AS rpt, wrap
      WHERE rpt.reported_dt >= wrap.wrap_dt
    ) AS report_cnt,
    (
      SELECT COUNT(*) FROM {{ ref('int_message_threads') }} AS imt, wrap
      WHERE (imt.sent_ts AT TIME ZONE 'utc')::DATE >= wrap.wrap_dt
    ) AS message_cnt,
    (
      SELECT COUNT(DISTINCT LOWER(TRIM(REGEXP_REPLACE(gcm.subject, '\s+', ' ', 'g'))))
      FROM {{ ref('int_git_commits') }} AS gcm, wrap
      WHERE
        gcm.branch != 'master' AND NOT gcm.is_plumbing
        AND (gcm.commit_ts AT TIME ZONE 'utc')::DATE > wrap.wrap_dt
    ) AS early_fix_cnt
),

estimates AS (
  SELECT
    'bug reports x ' || ROUND(rat.per_report, 2) AS estimator,
    1 AS estimator_order,
    sig.report_cnt AS signal_value,
    ROUND(sig.report_cnt * rat.per_report)::INTEGER AS projected_fix_cnt
  FROM current_signals AS sig, ratios AS rat
  UNION ALL
  SELECT
    'list messages x ' || ROUND(rat.per_message, 3) AS estimator,
    2 AS estimator_order,
    sig.message_cnt AS signal_value,
    ROUND(sig.message_cnt * rat.per_message)::INTEGER AS projected_fix_cnt
  FROM current_signals AS sig, ratios AS rat
  UNION ALL
  SELECT
    'committed fixes x ' || ROUND(rat.per_early_fix, 2) AS estimator,
    3 AS estimator_order,
    sig.early_fix_cnt AS signal_value,
    ROUND(sig.early_fix_cnt * rat.per_early_fix)::INTEGER AS projected_fix_cnt
  FROM current_signals AS sig, ratios AS rat
)

SELECT
  shp.ships_at_dt,
  est.estimator,
  est.estimator_order,
  est.signal_value,
  est.projected_fix_cnt
FROM estimates AS est, ships AS shp
UNION ALL
SELECT
  shp.ships_at_dt,
  'blended (equal weight)' AS estimator,
  4 AS estimator_order,
  null AS signal_value,
  ROUND(AVG(est.projected_fix_cnt))::INTEGER AS projected_fix_cnt
FROM estimates AS est, ships AS shp
GROUP BY ALL
