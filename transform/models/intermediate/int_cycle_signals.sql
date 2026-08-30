-- Every started release cycle (closed AND the current open one) with its three
-- early signals measured over the cycle's first N days, where N = the open
-- cycle's age — the shared base for the fix projections. Extracted here so
-- fix_projection_cycles (closed cycles, for the ratios) and
-- fix_projection_estimates (the open cycle's live signals) stop recomputing the
-- same windowed counts. shipped_fix_cnt is the wave the cycle produced (NULL for
-- the open cycle and any cycle with no matching scheduled wave). The early-fix
-- signal comes from int_backpatch_fixes (distinct by fix_key). Grain =
-- cycle_start_dt. All windows are half-open [start, start+N) for like-for-like.
WITH cycles AS (
  SELECT
    wrap_dt AS cycle_start_dt,
    LEAD(scheduled_release_dt) OVER (ORDER BY wrap_dt) AS ships_at_dt
  FROM {{ ref('int_release_calendar') }}
),

age AS (
  SELECT (CURRENT_DATE - MAX(cycle_start_dt))::INTEGER AS window_days
  FROM cycles
  WHERE cycle_start_dt <= CURRENT_DATE
),

shipped AS (
  SELECT
    cyc.cycle_start_dt,
    wvs.distinct_fix_cnt AS shipped_fix_cnt
  FROM cycles AS cyc
  INNER JOIN {{ ref('int_wave_summary') }} AS wvs
    ON wvs.wave_dt BETWEEN cyc.ships_at_dt - 3 AND cyc.ships_at_dt + 3
  WHERE NOT wvs.is_out_of_band AND NOT wvs.is_partial_window
),

early_reports AS (
  SELECT
    cyc.cycle_start_dt,
    COUNT(*) AS early_report_cnt
  FROM cycles AS cyc
  INNER JOIN {{ ref('int_bug_reports') }} AS rpt
    ON
      cyc.cycle_start_dt <= rpt.reported_dt
      AND rpt.reported_dt < cyc.cycle_start_dt + (SELECT age.window_days FROM age)
  GROUP BY ALL
),

early_messages AS (
  SELECT
    cyc.cycle_start_dt,
    COUNT(*) AS early_message_cnt
  FROM cycles AS cyc
  INNER JOIN {{ ref('int_message_threads') }} AS imt
    ON
      (imt.sent_ts AT TIME ZONE 'utc')::DATE >= cyc.cycle_start_dt
      AND (imt.sent_ts AT TIME ZONE 'utc')::DATE
      < cyc.cycle_start_dt + (SELECT age.window_days FROM age)
  GROUP BY ALL
),

early_fixes AS (
  SELECT
    cyc.cycle_start_dt,
    COUNT(DISTINCT bpf.fix_key) AS early_fix_cnt
  FROM cycles AS cyc
  INNER JOIN {{ ref('int_backpatch_fixes') }} AS bpf
    ON
      cyc.cycle_start_dt < bpf.commit_dt
      AND cyc.cycle_start_dt + (SELECT age.window_days FROM age) >= bpf.commit_dt
  GROUP BY ALL
)

SELECT
  cyc.cycle_start_dt,
  cyc.ships_at_dt,
  (SELECT age.window_days FROM age) AS window_days,
  shp.shipped_fix_cnt,
  COALESCE(erp.early_report_cnt, 0) AS early_report_cnt,
  COALESCE(ems.early_message_cnt, 0) AS early_message_cnt,
  COALESCE(efx.early_fix_cnt, 0) AS early_fix_cnt,
  cyc.ships_at_dt > CURRENT_DATE AS is_open_cycle
FROM cycles AS cyc
LEFT JOIN shipped AS shp ON cyc.cycle_start_dt = shp.cycle_start_dt
LEFT JOIN early_reports AS erp ON cyc.cycle_start_dt = erp.cycle_start_dt
LEFT JOIN early_messages AS ems ON cyc.cycle_start_dt = ems.cycle_start_dt
LEFT JOIN early_fixes AS efx ON cyc.cycle_start_dt = efx.cycle_start_dt
WHERE cyc.cycle_start_dt <= CURRENT_DATE
