WITH cycles AS (
  SELECT
    wrap_dt AS cycle_start_dt,
    LEAD(scheduled_release_dt) OVER (ORDER BY wrap_dt) AS ships_at_dt
  FROM {{ ref('int_release_calendar') }}
),

-- the open cycle's age, at least one day so the windows are never empty on
-- wrap Monday itself
age AS (
  SELECT GREATEST(({{ as_of_date() }} - MAX(cycle_start_dt))::INTEGER, 1) AS window_days
  FROM cycles
  WHERE cycle_start_dt <= {{ as_of_date() }}
),

-- reports and messages have no release to belong to, so they are windowed by date
early_reports AS (
  SELECT
    cyc.cycle_start_dt,
    COUNT(*) AS early_report_cnt
  FROM cycles AS cyc
  CROSS JOIN age
  INNER JOIN {{ ref('int_bug_reports') }} AS rpt
    ON cyc.cycle_start_dt <= rpt.reported_dt AND rpt.reported_dt < cyc.cycle_start_dt + age.window_days
  GROUP BY ALL
),

early_messages AS (
  SELECT
    cyc.cycle_start_dt,
    COUNT(*) AS early_message_cnt
  FROM cycles AS cyc
  CROSS JOIN age
  INNER JOIN {{ ref('int_message_threads') }} AS imt
    ON cyc.cycle_start_dt <= imt.sent_dt AND imt.sent_dt < cyc.cycle_start_dt + age.window_days
  GROUP BY ALL
),

-- a cycle's committed fixes: those of every release shipping in it (the
-- scheduled one plus a mid-cycle out-of-band re-release)
cycle_fixes AS (
  SELECT
    cyc.cycle_start_dt,
    cfx.fix_key,
    cfx.first_commit_dt
  FROM cycles AS cyc
  INNER JOIN {{ ref('int_releases') }} AS irl ON cyc.ships_at_dt = irl.cycle_ships_at_dt
  INNER JOIN {{ ref('int_committed_fixes') }} AS cfx ON irl.release_dt = cfx.release_dt
),

fix_counts AS (
  SELECT
    cfx.cycle_start_dt,
    COUNT(DISTINCT cfx.fix_key) AS full_fix_cnt,
    -- the open cycle's age window (drifts out to the full cycle by release day)
    COUNT(DISTINCT cfx.fix_key) FILTER (
      WHERE cfx.cycle_start_dt + age.window_days >= cfx.first_commit_dt
    ) AS early_fix_cnt,
    -- the fixed first-N-day window, stable across builds
    COUNT(DISTINCT cfx.fix_key) FILTER (
      WHERE cfx.cycle_start_dt + {{ var('seasonality_window_days') }} >= cfx.first_commit_dt
    ) AS first_window_fix_cnt
  FROM cycle_fixes AS cfx
  CROSS JOIN age
  GROUP BY ALL
)

SELECT
  cyc.ships_at_dt,
  cyc.cycle_start_dt,
  age.window_days,
  COALESCE(erp.early_report_cnt, 0) AS early_report_cnt,
  COALESCE(ems.early_message_cnt, 0) AS early_message_cnt,
  COALESCE(fxc.early_fix_cnt, 0) AS early_fix_cnt,
  COALESCE(fxc.full_fix_cnt, 0) AS full_fix_cnt,
  COALESCE(fxc.first_window_fix_cnt, 0) AS first_window_fix_cnt
FROM cycles AS cyc
CROSS JOIN age
LEFT JOIN early_reports AS erp ON cyc.cycle_start_dt = erp.cycle_start_dt
LEFT JOIN early_messages AS ems ON cyc.cycle_start_dt = ems.cycle_start_dt
LEFT JOIN fix_counts AS fxc ON cyc.cycle_start_dt = fxc.cycle_start_dt
-- started cycles only, and only those shipping a corpus release (or still open)
WHERE
  cyc.cycle_start_dt <= {{ as_of_date() }}
  AND cyc.ships_at_dt >= (
    SELECT MIN(irl.release_dt)
    FROM {{ ref('int_releases') }} AS irl
    WHERE irl.status = 'shipped'
  )
