-- Next-wave scenarios from the full-quarter wave series (out-of-band and
-- partial-window waves excluded). The trend fit indexes waves 0..n-1 and
-- extends the least-squares line one slot; "reversion" returns to the mean
-- of the three full-quarter waves BEFORE the latest, with a +/- one
-- standard-deviation band (stdev over everything but the latest wave).
WITH fullq AS (
  SELECT
    wave_dt,
    distinct_fix_cnt,
    ROW_NUMBER() OVER (ORDER BY wave_dt) - 1 AS idx
  FROM {{ ref('int_wave_summary') }}
  WHERE NOT is_out_of_band AND NOT is_partial_window
),

fit AS (
  SELECT
    COUNT(*) AS wave_cnt,
    REGR_INTERCEPT(distinct_fix_cnt, idx) AS intercept,
    REGR_SLOPE(distinct_fix_cnt, idx) AS slope
  FROM fullq
),

latest AS (
  SELECT
    distinct_fix_cnt AS latest_fixes,
    wave_dt + 91 AS projected_dt
  FROM fullq
  ORDER BY idx DESC
  LIMIT 1
),

stats AS (
  SELECT
    (
      SELECT AVG(fullq.distinct_fix_cnt)
      FROM fullq, fit
      WHERE fullq.idx BETWEEN fit.wave_cnt - 4 AND fit.wave_cnt - 2
    ) AS baseline,
    (
      SELECT STDDEV_SAMP(fullq.distinct_fix_cnt)
      FROM fullq, fit
      WHERE fullq.idx <= fit.wave_cnt - 2
    ) AS sdev
),

scenarios AS (
  SELECT
    'reversion' AS scenario,
    0 AS scenario_order,
    latest.projected_dt,
    ROUND(stats.baseline)::INTEGER AS distinct_fix_cnt,
    ROUND(stats.baseline - stats.sdev)::INTEGER AS low,
    ROUND(stats.baseline + stats.sdev)::INTEGER AS high,
    'latest wave was a one-off; return to the mean of the prior three full-quarter waves' AS assumption
  FROM latest, stats
  UNION ALL
  SELECT
    'trend' AS scenario,
    1 AS scenario_order,
    latest.projected_dt,
    ROUND(fit.intercept + fit.slope * fit.wave_cnt)::INTEGER AS distinct_fix_cnt,
    null AS low,
    null AS high,
    'least-squares line through all full-quarter waves, extended one slot' AS assumption
  FROM latest, fit
  UNION ALL
  SELECT
    'regime repeat' AS scenario,
    2 AS scenario_order,
    latest.projected_dt,
    latest.latest_fixes AS distinct_fix_cnt,
    null AS low,
    null AS high,
    'whatever produced the latest wave keeps delivering at that level' AS assumption
  FROM latest
  UNION ALL
  SELECT
    'escalation' AS scenario,
    3 AS scenario_order,
    latest.projected_dt,
    ROUND(latest.latest_fixes + fit.slope)::INTEGER AS distinct_fix_cnt,
    null AS low,
    null AS high,
    'latest wave is the new base and growth continues at the fitted trend rate' AS assumption
  FROM latest, fit
)

SELECT *
FROM scenarios
