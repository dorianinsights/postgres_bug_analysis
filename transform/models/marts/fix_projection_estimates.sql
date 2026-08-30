-- Simple linear estimates for the upcoming minor's fix count: the
-- current cycle's three early signals scaled by each signal's historical
-- median shipped-per-early ratio (medians over fix_projection_cycles,
-- which replays every closed cycle at today's cycle age), plus an
-- equal-weight blend. Deliberately naive — the point is a transparent,
-- explainable band, not a fitted model. The demand-side estimators
-- (reports, messages) assume the historical signal->fix conversion; the
-- supply-side estimator (committed pace) is what caught the Aug 2026
-- surge, where fixes grew without proportional inbound reports.
WITH ships AS (
  SELECT MIN(scheduled_release_dt) AS ships_at_dt
  FROM {{ ref('int_release_calendar') }}
  WHERE scheduled_release_dt > CURRENT_DATE
),

-- shipped-per-signal ratios over the closed cycles (with all three signals
-- present, so the medians never divide by zero)
ratios AS (
  SELECT
    MEDIAN(shipped_fix_cnt * 1.0 / early_report_cnt) AS per_report,
    MEDIAN(shipped_fix_cnt * 1.0 / early_message_cnt) AS per_message,
    MEDIAN(shipped_fix_cnt * 1.0 / early_fix_cnt) AS per_early_fix
  FROM {{ ref('fct_release_cycles') }}
  WHERE
    shipped_fix_cnt IS NOT null
    AND early_report_cnt > 0
    AND early_message_cnt > 0
    AND early_fix_cnt > 0
),

-- the open cycle's live signals, from the same windowed source the ratios use
current_signals AS (
  SELECT
    early_report_cnt AS report_cnt,
    early_message_cnt AS message_cnt,
    early_fix_cnt
  FROM {{ ref('fct_release_cycles') }}
  WHERE is_open_cycle
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
