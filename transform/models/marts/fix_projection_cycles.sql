-- Every closed release cycle replayed at the CURRENT cycle's age: the
-- three early signals (bug reports, list messages, distinct fixes
-- committed) measured over each cycle's first N days, where N = days
-- since the open cycle's wrap — a like-for-like base for linear
-- projections of the upcoming wave. Rebuilds daily as N grows. Scheduled
-- waves only (out-of-band and the partial first wave excluded).
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

outcomes AS (
  SELECT
    cyc.cycle_start_dt,
    cyc.ships_at_dt,
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
    COUNT(DISTINCT LOWER(TRIM(REGEXP_REPLACE(gcm.subject, '\s+', ' ', 'g'))))
      AS early_fix_cnt
  FROM cycles AS cyc
  INNER JOIN {{ ref('int_git_commits') }} AS gcm
    ON
      (gcm.commit_ts AT TIME ZONE 'utc')::DATE > cyc.cycle_start_dt
      AND (gcm.commit_ts AT TIME ZONE 'utc')::DATE
      <= cyc.cycle_start_dt + (SELECT age.window_days FROM age)
  WHERE gcm.branch != 'master' AND NOT gcm.is_plumbing
  GROUP BY ALL
)

SELECT
  ocm.ships_at_dt,
  (SELECT age.window_days FROM age) AS window_days,
  ocm.shipped_fix_cnt,
  erp.early_report_cnt,
  ems.early_message_cnt,
  efx.early_fix_cnt
FROM outcomes AS ocm
INNER JOIN early_reports AS erp ON ocm.cycle_start_dt = erp.cycle_start_dt
INNER JOIN early_messages AS ems ON ocm.cycle_start_dt = ems.cycle_start_dt
INNER JOIN early_fixes AS efx ON ocm.cycle_start_dt = efx.cycle_start_dt
