-- Forecast fact: what each projection method (seed projection_methods) says a
-- scheduled release's DOCUMENTED fix count will be, for EVERY started scheduled
-- cycle -- the open one (the live forecast) and every shipped one, replayed
-- using only the releases before it -- so the actual
-- (dim_release.distinct_fix_cnt on the same dim_release_key) scores each
-- method release by release. Kimball forecast-vs-actual: the estimated measure
-- lives here, the observed one on the release dimension, joined on the
-- conformed key; projection_method is the method dimension, a seed lookup
-- whose attributes (family, order, label, assumption) are denormalized onto
-- the row like category_order on the category aggregates. Replaces the
-- single-open-release marts `projections` (the four series scenarios) and
-- `fix_projection_estimates` (the signal estimators), and absorbs
-- fct_fix_origins_agg's per-origin projected_fix_cnt as origin_scaled.
--
-- Targets are the full-quarter scheduled releases with cycle signals (the
-- out-of-band re-releases and the corpus's partial-window first release are
-- neither forecast nor part of any method's history). Slot = the target's
-- position in that series; a method's history is the shipped targets with a
-- lower slot, so nothing leaks from the release being forecast:
--   series   trend fits a least-squares line over the history and extends it
--            one slot; reversion returns to the mean of the
--            var(reversion_baseline_releases) releases before the latest with
--            a +/- one-sample-stdev band over everything but the latest;
--            regime_repeat copies the latest; escalation adds the fitted slope
--            to it.
--   signal   the target's own early signal (dim_release.early_*_cnt, at the
--            open cycle's current age) times the median shipped-per-early
--            ratio over the history cycles that have all three signals;
--            origin_scaled scales each origin's early committed fixes by the
--            origin's documented-per-early-committed factor pooled over the
--            var(origin_projection_cycles) history releases before the target
--            (an origin with no early commits -- embargoed security -- takes
--            those releases' average documented count), summed over origins.
--            The factor's numerator is the scheduled release's own documented
--            fixes (release grain, the actual it is scored against, like
--            committed_scaled's ratio); only its early-committed denominator
--            folds a mid-cycle out-of-band release into its cycle
--            (int_releases.cycle_ships_at_dt), since those commits were
--            produced in the cycle.
--   reference blended is the equal-weight mean of the three single-signal
--            estimates; seasonal_baseline the median shipped count of the
--            history releases in the target's calendar quarter.
-- A method with too little history for a target (the first few slots) has no
-- row. Every early signal is measured at the OPEN cycle's current age
-- (int_release_cycles.window_days, floored at one day), for the open target
-- and every replayed one alike, so the signal-family and blended rows change
-- daily and the backtest re-ranks with them; below
-- var(projection_min_window_days) of age the signals are a few days of noise
-- and those rows are withheld (the series and seasonal rows never depend on
-- the age). Grain = (dim_release_key, projection_method).
-- -> data/derived/fct_fix_projections.csv
WITH targets AS (
  SELECT
    dim_release_key,
    release_dt,
    distinct_fix_cnt,
    window_days,
    early_report_cnt,
    early_message_cnt,
    early_fix_cnt,
    fix_per_early_report,
    fix_per_early_message,
    fix_per_early_fix,
    ROW_NUMBER() OVER (ORDER BY release_dt) - 1 AS slot
  FROM {{ ref('dim_release') }}
  WHERE
    NOT is_synthetic_row
    AND NOT is_out_of_band
    AND NOT is_partial_window
    AND status IN ('shipped', 'open')
    AND cycle_start_dt IS NOT null
),

-- the series methods' inputs per target, over its history (lower slots)
series_fit AS (
  SELECT
    tgt.dim_release_key,
    tgt.slot,
    -- a one-point history has no line (DuckDB's REGR_* return NaN, not NULL)
    CASE WHEN COUNT(*) > 1 THEN REGR_INTERCEPT(hst.distinct_fix_cnt, hst.slot) END AS intercept,
    CASE WHEN COUNT(*) > 1 THEN REGR_SLOPE(hst.distinct_fix_cnt, hst.slot) END AS slope,
    MAX(hst.distinct_fix_cnt) FILTER (WHERE hst.slot = tgt.slot - 1) AS latest_fix_cnt,
    AVG(hst.distinct_fix_cnt) FILTER (
      WHERE hst.slot < tgt.slot - 1 AND hst.slot >= tgt.slot - 1 - {{ var('reversion_baseline_releases') }}
    ) AS baseline,
    COUNT(*) FILTER (
      WHERE hst.slot < tgt.slot - 1 AND hst.slot >= tgt.slot - 1 - {{ var('reversion_baseline_releases') }}
    ) AS baseline_cnt,
    STDDEV_SAMP(hst.distinct_fix_cnt) FILTER (WHERE hst.slot < tgt.slot - 1) AS sdev
  FROM targets AS tgt
  INNER JOIN targets AS hst ON tgt.slot > hst.slot
  GROUP BY tgt.dim_release_key, tgt.slot
),

-- median shipped-per-early-signal ratios over the history cycles that carry
-- all three signals (so no median is over a zero-signal cycle)
signal_ratios AS (
  SELECT
    tgt.dim_release_key,
    MEDIAN(hst.fix_per_early_report) AS per_report,
    MEDIAN(hst.fix_per_early_message) AS per_message,
    MEDIAN(hst.fix_per_early_fix) AS per_early_fix
  FROM targets AS tgt
  INNER JOIN targets AS hst ON tgt.slot > hst.slot
  WHERE
    hst.distinct_fix_cnt IS NOT null
    AND hst.early_report_cnt > 0
    AND hst.early_message_cnt > 0
    AND hst.early_fix_cnt > 0
  GROUP BY tgt.dim_release_key
),

seasonal AS (
  SELECT
    tgt.dim_release_key,
    MEDIAN(hst.distinct_fix_cnt) AS baseline_fix_cnt
  FROM targets AS tgt
  INNER JOIN targets AS hst
    ON tgt.slot > hst.slot AND QUARTER(tgt.release_dt) = QUARTER(hst.release_dt)
  WHERE hst.distinct_fix_cnt IS NOT null
  GROUP BY tgt.dim_release_key
),

-- origin_scaled: documented fixes per (scheduled release, origin), release
-- grain -- a fix none of whose annotated commits matched the corpus has no
-- origin row: no public trail, split by its CVE mention like the rest
documented_by_release AS (
  SELECT
    reps.release_dt,
    COALESCE(org.origin, {{ resolve_fix_origin('false', 'false', 'reps.cves IS NOT null') }}) AS origin,
    COUNT(*) AS fix_cnt
  FROM {{ ref('int_fix_reps') }} AS reps
  LEFT JOIN {{ ref('int_fix_origins') }} AS org ON reps.item_ord = org.group_ord
  GROUP BY ALL
),

-- ... and the distinct committed fixes per (cycle, origin) that had landed by
-- the open cycle's current age (int_release_cycles.window_days), the same age
-- every early count is measured at; a mid-cycle out-of-band release's commits
-- fold into the scheduled cycle that produced them
early_committed_by_cycle AS (
  SELECT
    irl.cycle_ships_at_dt AS ships_at_dt,
    cfx.origin,
    COUNT(DISTINCT cfx.fix_key) AS early_fix_cnt
  FROM {{ ref('int_release_cycles') }} AS irc
  INNER JOIN {{ ref('int_releases') }} AS irl ON irc.ships_at_dt = irl.cycle_ships_at_dt
  INNER JOIN {{ ref('int_committed_fixes') }} AS cfx
    ON irl.release_dt = cfx.release_dt AND irc.cycle_start_dt + irc.window_days >= cfx.first_commit_dt
  GROUP BY ALL
),

origins AS (
  SELECT origin FROM documented_by_release
  UNION
  SELECT origin FROM early_committed_by_cycle
),

-- each target's comparator releases: the most recent history releases
comparators AS (
  SELECT
    tgt.dim_release_key,
    hst.release_dt
  FROM targets AS tgt
  INNER JOIN targets AS hst ON tgt.slot > hst.slot
  QUALIFY
    ROW_NUMBER() OVER (PARTITION BY tgt.dim_release_key ORDER BY hst.slot DESC)
    <= {{ var('origin_projection_cycles') }}
),

origin_factors AS (
  SELECT
    cmp.dim_release_key,
    org.origin,
    SUM(COALESCE(doc.fix_cnt, 0)) AS documented_sum,
    SUM(COALESCE(ecm.early_fix_cnt, 0)) AS early_sum,
    AVG(COALESCE(doc.fix_cnt, 0)) AS documented_avg
  FROM comparators AS cmp
  CROSS JOIN origins AS org
  LEFT JOIN documented_by_release AS doc ON cmp.release_dt = doc.release_dt AND org.origin = doc.origin
  LEFT JOIN early_committed_by_cycle AS ecm ON cmp.release_dt = ecm.ships_at_dt AND org.origin = ecm.origin
  GROUP BY ALL
),

-- the target's own early committed fixes per origin, scaled and summed; an
-- origin the target has no early commits for (or whose comparators had none)
-- is projected at the comparators' average documented count instead
origin_projection AS (
  SELECT
    tgt.dim_release_key,
    SUM(COALESCE(ecm.early_fix_cnt, 0))::BIGINT AS early_fix_cnt,
    SUM(
      CASE
        WHEN COALESCE(ecm.early_fix_cnt, 0) > 0 AND fac.early_sum > 0
          THEN ecm.early_fix_cnt * fac.documented_sum / fac.early_sum
        ELSE fac.documented_avg
      END
    ) AS projected_fix_cnt
  FROM targets AS tgt
  INNER JOIN origin_factors AS fac ON tgt.dim_release_key = fac.dim_release_key
  LEFT JOIN early_committed_by_cycle AS ecm ON tgt.release_dt = ecm.ships_at_dt AND fac.origin = ecm.origin
  WHERE tgt.window_days >= {{ var('projection_min_window_days') }}
  GROUP BY tgt.dim_release_key
),

signal_estimates AS (
  SELECT
    tgt.dim_release_key,
    'report_scaled' AS projection_method,
    tgt.early_report_cnt AS signal_value,
    rat.per_report::DECIMAL(12, 6) AS scale_factor,
    ROUND(tgt.early_report_cnt * rat.per_report)::BIGINT AS projected_fix_cnt
  FROM targets AS tgt
  INNER JOIN signal_ratios AS rat ON tgt.dim_release_key = rat.dim_release_key
  WHERE tgt.window_days >= {{ var('projection_min_window_days') }}
  UNION ALL
  SELECT
    tgt.dim_release_key,
    'message_scaled' AS projection_method,
    tgt.early_message_cnt AS signal_value,
    rat.per_message::DECIMAL(12, 6) AS scale_factor,
    ROUND(tgt.early_message_cnt * rat.per_message)::BIGINT AS projected_fix_cnt
  FROM targets AS tgt
  INNER JOIN signal_ratios AS rat ON tgt.dim_release_key = rat.dim_release_key
  WHERE tgt.window_days >= {{ var('projection_min_window_days') }}
  UNION ALL
  SELECT
    tgt.dim_release_key,
    'committed_scaled' AS projection_method,
    tgt.early_fix_cnt AS signal_value,
    rat.per_early_fix::DECIMAL(12, 6) AS scale_factor,
    ROUND(tgt.early_fix_cnt * rat.per_early_fix)::BIGINT AS projected_fix_cnt
  FROM targets AS tgt
  INNER JOIN signal_ratios AS rat ON tgt.dim_release_key = rat.dim_release_key
  WHERE tgt.window_days >= {{ var('projection_min_window_days') }}
),

estimates AS (
  SELECT
    dim_release_key,
    'reversion' AS projection_method,
    null AS signal_value,
    null AS scale_factor,
    ROUND(baseline)::BIGINT AS projected_fix_cnt,
    ROUND(baseline - sdev)::BIGINT AS low_fix_cnt,
    ROUND(baseline + sdev)::BIGINT AS high_fix_cnt
  FROM series_fit
  WHERE baseline_cnt = {{ var('reversion_baseline_releases') }}
  UNION ALL
  SELECT
    dim_release_key,
    'trend' AS projection_method,
    null AS signal_value,
    null AS scale_factor,
    ROUND(intercept + slope * slot)::BIGINT AS projected_fix_cnt,
    null AS low_fix_cnt,
    null AS high_fix_cnt
  FROM series_fit
  WHERE slope IS NOT null
  UNION ALL
  SELECT
    dim_release_key,
    'regime_repeat' AS projection_method,
    null AS signal_value,
    null AS scale_factor,
    latest_fix_cnt::BIGINT AS projected_fix_cnt,
    null AS low_fix_cnt,
    null AS high_fix_cnt
  FROM series_fit
  UNION ALL
  SELECT
    dim_release_key,
    'escalation' AS projection_method,
    null AS signal_value,
    null AS scale_factor,
    ROUND(latest_fix_cnt + slope)::BIGINT AS projected_fix_cnt,
    null AS low_fix_cnt,
    null AS high_fix_cnt
  FROM series_fit
  WHERE slope IS NOT null
  UNION ALL
  SELECT
    dim_release_key,
    projection_method,
    signal_value,
    scale_factor,
    projected_fix_cnt,
    null AS low_fix_cnt,
    null AS high_fix_cnt
  FROM signal_estimates
  UNION ALL
  SELECT
    dim_release_key,
    'origin_scaled' AS projection_method,
    early_fix_cnt AS signal_value,
    null AS scale_factor,
    ROUND(projected_fix_cnt)::BIGINT AS projected_fix_cnt,
    null AS low_fix_cnt,
    null AS high_fix_cnt
  FROM origin_projection
  UNION ALL
  SELECT
    dim_release_key,
    'blended' AS projection_method,
    null AS signal_value,
    null AS scale_factor,
    ROUND(AVG(projected_fix_cnt))::BIGINT AS projected_fix_cnt,
    null AS low_fix_cnt,
    null AS high_fix_cnt
  FROM signal_estimates
  GROUP BY dim_release_key
  UNION ALL
  SELECT
    dim_release_key,
    'seasonal_baseline' AS projection_method,
    null AS signal_value,
    null AS scale_factor,
    ROUND(baseline_fix_cnt)::BIGINT AS projected_fix_cnt,
    null AS low_fix_cnt,
    null AS high_fix_cnt
  FROM seasonal
)

-- explicit projection (not SELECT *): dct validate derives each model's
-- columns statically from this SQL to check the faces' queries against them
SELECT
  tgt.dim_release_key,
  tgt.release_dt,
  est.projection_method,
  mth.method_label,
  mth.method_family,
  mth.method_order,
  est.signal_value,
  est.scale_factor,
  est.projected_fix_cnt,
  est.low_fix_cnt,
  est.high_fix_cnt,
  mth.assumption
FROM estimates AS est
INNER JOIN targets AS tgt ON est.dim_release_key = tgt.dim_release_key
INNER JOIN {{ ref('projection_methods') }} AS mth ON est.projection_method = mth.projection_method
