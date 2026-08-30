-- Cycle-grain fact: one row per started release cycle (closed + the open one),
-- unifying the three former cycle tables (int_cycle_signals, git_cycle_pace,
-- fix_projection_cycles). Carries the three early signals over the open cycle's
-- age-window (for the projections), the like-for-like pace (early vs full
-- distinct backpatched fixes), and the shipped fix count for closed cycles.
-- Conforms to dim_release_cycle via cycle_key. All windows are half-open
-- [start, start+N) at the open cycle's age N; the full window runs to the next
-- cycle's wrap (or today). Grain = cycle_key. -> ../data/derived/fct_release_cycles.csv
WITH cycles AS (
  SELECT
    wrap_dt AS cycle_start_dt,
    LEAD(scheduled_release_dt) OVER (ORDER BY wrap_dt) AS ships_at_dt,
    LEAD(wrap_dt) OVER (ORDER BY wrap_dt) AS next_cycle_start_dt
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
),

full_fixes AS (
  SELECT
    cyc.cycle_start_dt,
    COUNT(DISTINCT bpf.fix_key) AS full_fix_cnt
  FROM cycles AS cyc
  INNER JOIN {{ ref('int_backpatch_fixes') }} AS bpf
    ON
      cyc.cycle_start_dt < bpf.commit_dt
      AND LEAST(COALESCE(cyc.next_cycle_start_dt, CURRENT_DATE), CURRENT_DATE) >= bpf.commit_dt
  GROUP BY ALL
)

SELECT
  STRFTIME(cyc.ships_at_dt, '%Y%m%d')::INTEGER AS cycle_key,
  cyc.cycle_start_dt,
  cyc.ships_at_dt,
  (SELECT age.window_days FROM age) AS window_days,
  cyc.ships_at_dt > CURRENT_DATE AS is_open_cycle,
  shp.shipped_fix_cnt,
  COALESCE(erp.early_report_cnt, 0) AS early_report_cnt,
  COALESCE(ems.early_message_cnt, 0) AS early_message_cnt,
  COALESCE(efx.early_fix_cnt, 0) AS early_fix_cnt,
  COALESCE(ffx.full_fix_cnt, 0) AS full_fix_cnt
FROM cycles AS cyc
LEFT JOIN shipped AS shp ON cyc.cycle_start_dt = shp.cycle_start_dt
LEFT JOIN early_reports AS erp ON cyc.cycle_start_dt = erp.cycle_start_dt
LEFT JOIN early_messages AS ems ON cyc.cycle_start_dt = ems.cycle_start_dt
LEFT JOIN early_fixes AS efx ON cyc.cycle_start_dt = efx.cycle_start_dt
LEFT JOIN full_fixes AS ffx ON cyc.cycle_start_dt = ffx.cycle_start_dt
-- started cycles only, and only those shipping a corpus release (or still open)
-- — cycles shipping a pre-corpus scheduled date have no wave and are noise
WHERE
  cyc.cycle_start_dt <= CURRENT_DATE
  AND cyc.ships_at_dt >= (SELECT MIN(iws.wave_dt) FROM {{ ref('int_wave_summary') }} AS iws)
