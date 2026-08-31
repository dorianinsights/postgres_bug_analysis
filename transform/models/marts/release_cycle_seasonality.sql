-- Per-cycle backpatch-fix pace for the quarterly-seasonality analysis: how many
-- distinct backpatched fixes land in the FIXED first-N-day window after the wrap
-- (var seasonality_window_days) vs across the full cycle, one row per closed
-- scheduled release cycle, tagged by its release quarter/month. The window is
-- fixed on purpose -- unlike dim_release/int_release_cycles' early_fix_cnt, which
-- tracks the open cycle's moving age for the projection; a stable window is what
-- makes the seasonality comparable across years. Scoped to closed, non-partial
-- corpus cycles (the full window is complete only for those).
-- Grain = release_dt. -> ../data/derived/release_cycle_seasonality.csv
{% set win = var('seasonality_window_days') %}
WITH cycles AS (
  SELECT
    wrap_dt AS cycle_start_dt,
    LEAD(scheduled_release_dt) OVER (ORDER BY wrap_dt) AS release_dt,
    LEAD(wrap_dt) OVER (ORDER BY wrap_dt) AS next_cycle_start_dt
  FROM {{ ref('int_release_calendar') }}
),

scoped AS (
  SELECT
    cyc.cycle_start_dt,
    cyc.release_dt,
    LEAST(COALESCE(cyc.next_cycle_start_dt, CURRENT_DATE), CURRENT_DATE) AS cycle_end_dt
  FROM cycles AS cyc
  WHERE
    cyc.release_dt <= CURRENT_DATE
    AND cyc.release_dt >= (
      SELECT MIN(wsm.wave_dt)
      FROM {{ ref('int_wave_summary') }} AS wsm
      WHERE NOT wsm.is_partial_window
    )
),

counts AS (
  SELECT
    scp.release_dt,
    COUNT(DISTINCT CASE WHEN bpf.commit_dt <= scp.cycle_start_dt + {{ win }} THEN bpf.fix_key END) AS early_fix_cnt,
    COUNT(DISTINCT bpf.fix_key) AS full_fix_cnt
  FROM scoped AS scp
  INNER JOIN {{ ref('int_backpatch_fixes') }} AS bpf
    ON scp.cycle_start_dt < bpf.commit_dt AND scp.cycle_end_dt >= bpf.commit_dt
  GROUP BY ALL
)

SELECT
  release_dt,
  QUARTER(release_dt) AS release_quarter,
  STRFTIME(release_dt, '%b') AS release_month,
  {{ win }} AS early_window_days,
  early_fix_cnt,
  full_fix_cnt,
  ROUND(early_fix_cnt * 1.0 / full_fix_cnt, 4) AS early_fix_share
FROM counts
