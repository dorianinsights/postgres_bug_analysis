-- Cycle-grain signals for each started release cycle, folded into dim_release
-- (a cycle IS a release at an earlier lifecycle stage, so these ride on the
-- release row rather than a separate 1:1 fact). One row per started scheduled
-- cycle (closed + the open one); joins to dim_release on ships_at_dt =
-- release_dt. Carries the three early signals over the open cycle's age-window
-- (for the projections), the like-for-like pace (early vs full distinct
-- committed fixes), the window itself, and first_window_fix_cnt over a FIXED
-- window (var seasonality_window_days) for the stable quarterly-seasonality
-- view. The shipped (documented) fix count is NOT here -- it is
-- dim_release.distinct_fix_cnt on the same row.
--
-- The fix signals read int_committed_fixes, where each committed fix already
-- belongs to the release it ships in (tag ancestry; the open release for
-- not-yet-tagged commits) -- no date windows here. A cycle's fixes are those
-- of every release whose int_releases.cycle_ships_at_dt is the cycle's ship
-- day: the scheduled release itself plus any out-of-band re-release that
-- shipped mid-cycle (its fixes were produced in this cycle, so the pace and
-- seasonality views keep them). A fix is early when its first commit landed
-- within window_days of the cycle start (the PRIOR quarter's wrap). Reports
-- and messages are still windowed by date -- they have no release to belong
-- to. cycle_start_dt is distinct from the release's own wrap_dt.
-- Grain = ships_at_dt.
WITH cycles AS (
  SELECT
    wrap_dt AS cycle_start_dt,
    LEAD(scheduled_release_dt) OVER (ORDER BY wrap_dt) AS ships_at_dt
  FROM {{ ref('int_release_calendar') }}
),

-- the open cycle's age; at least one day, so the windows are never empty on
-- wrap Monday itself (a zero-day window would fail the window_days floor)
age AS (
  SELECT GREATEST(({{ as_of_date() }} - MAX(cycle_start_dt))::INTEGER, 1) AS window_days
  FROM cycles
  WHERE cycle_start_dt <= {{ as_of_date() }}
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
      cyc.cycle_start_dt <= imt.sent_dt
      AND cyc.cycle_start_dt + (SELECT age.window_days FROM age)
      > imt.sent_dt
  GROUP BY ALL
),

-- the cycle's committed fixes: those of every release shipping in the cycle
-- (the scheduled one, pending or shipped, plus a mid-cycle out-of-band one)
cycle_fixes AS (
  SELECT
    cyc.cycle_start_dt,
    cfx.fix_key,
    cfx.first_commit_dt
  FROM cycles AS cyc
  INNER JOIN {{ ref('int_releases') }} AS irl ON cyc.ships_at_dt = irl.cycle_ships_at_dt
  INNER JOIN {{ ref('int_committed_fixes') }} AS cfx ON irl.release_dt = cfx.release_dt
),

early_fixes AS (
  SELECT
    cycle_start_dt,
    COUNT(DISTINCT fix_key) AS early_fix_cnt
  FROM cycle_fixes
  WHERE cycle_start_dt + (SELECT age.window_days FROM age) >= first_commit_dt
  GROUP BY ALL
),

full_fixes AS (
  SELECT
    cycle_start_dt,
    COUNT(DISTINCT fix_key) AS full_fix_cnt
  FROM cycle_fixes
  GROUP BY ALL
),

-- the FIXED first-N-day window (var seasonality_window_days) for the quarterly
-- seasonality view -- stable across builds, unlike the age-window early_fix_cnt
-- above, which drifts out to the full cycle by release day
first_window_fixes AS (
  SELECT
    cycle_start_dt,
    COUNT(DISTINCT fix_key) AS first_window_fix_cnt
  FROM cycle_fixes
  WHERE cycle_start_dt + {{ var('seasonality_window_days') }} >= first_commit_dt
  GROUP BY ALL
)

SELECT
  cyc.ships_at_dt,
  cyc.cycle_start_dt,
  (SELECT age.window_days FROM age) AS window_days,
  COALESCE(erp.early_report_cnt, 0) AS early_report_cnt,
  COALESCE(ems.early_message_cnt, 0) AS early_message_cnt,
  COALESCE(efx.early_fix_cnt, 0) AS early_fix_cnt,
  COALESCE(ffx.full_fix_cnt, 0) AS full_fix_cnt,
  COALESCE(fwf.first_window_fix_cnt, 0) AS first_window_fix_cnt
FROM cycles AS cyc
LEFT JOIN early_reports AS erp ON cyc.cycle_start_dt = erp.cycle_start_dt
LEFT JOIN early_messages AS ems ON cyc.cycle_start_dt = ems.cycle_start_dt
LEFT JOIN early_fixes AS efx ON cyc.cycle_start_dt = efx.cycle_start_dt
LEFT JOIN full_fixes AS ffx ON cyc.cycle_start_dt = ffx.cycle_start_dt
LEFT JOIN first_window_fixes AS fwf ON cyc.cycle_start_dt = fwf.cycle_start_dt
-- started cycles only, and only those shipping a corpus release (or still open)
-- — cycles shipping a pre-corpus scheduled date have no release and are noise
WHERE
  cyc.cycle_start_dt <= {{ as_of_date() }}
  AND cyc.ships_at_dt >= (
    SELECT MIN(irl.release_dt)
    FROM {{ ref('int_releases') }} AS irl
    WHERE irl.status = 'shipped'
  )
