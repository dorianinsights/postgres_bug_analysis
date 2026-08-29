{{ config(materialized='external', location='../data/derived/git_cycle_pace.csv', format='csv') }}

-- Distinct stable-branch fixes in each recent cycle's first N days, where
-- N = the open cycle's age — the like-for-like pace comparison for the open
-- cycle. Cycle boundaries are the wrap moments of SCHEDULED waves only (the
-- latest tag date within a week before each scheduled release date) —
-- out-of-band re-wraps don't reset the pipeline clock. "Today" is the UTC
-- date, matching git's commit timestamps. A commit is a fix when it is on a
-- stable branch and not release plumbing; distinctness is by normalized
-- subject line (the same fix backpatched to several branches repeats its
-- subject verbatim).
WITH sched_waves AS (
  SELECT wave_dt
  FROM {{ ref('int_wave_summary') }}
  WHERE out_of_band = 0
  ORDER BY wave_dt DESC
  LIMIT 3  -- n_cycles: the open cycle plus two closed comparators
),

wraps AS (
  SELECT
    swv.wave_dt,
    MAX((tag.tag_ts AT TIME ZONE 'utc')::DATE) AS cycle_start_dt
  FROM sched_waves AS swv
  INNER JOIN {{ ref('stg_git_tags') }} AS tag
    ON (tag.tag_ts AT TIME ZONE 'utc')::DATE BETWEEN swv.wave_dt - 7 AND swv.wave_dt
  GROUP BY swv.wave_dt
),

today AS (
  SELECT (NOW() AT TIME ZONE 'utc')::DATE AS utc_today
),

cycles AS (
  SELECT
    cycle_start_dt,
    LEAD(cycle_start_dt) OVER (ORDER BY cycle_start_dt) AS next_wrap
  FROM wraps
),

open_age AS (
  -- DATE - DATE yields BIGINT; DATE + n only accepts INTEGER, hence the cast
  SELECT (tdy.utc_today - MAX(cyc.cycle_start_dt))::INTEGER AS window_days
  FROM cycles AS cyc, today AS tdy
  GROUP BY tdy.utc_today
),

bounded AS (
  SELECT
    cyc.cycle_start_dt,
    cyc.next_wrap,
    (cyc.next_wrap IS null)::INTEGER AS is_open_cycle,
    age.window_days,
    LEAST(cyc.cycle_start_dt + age.window_days, COALESCE(cyc.next_wrap, tdy.utc_today)) AS early_end,
    COALESCE(cyc.next_wrap, tdy.utc_today) AS full_end
  FROM cycles AS cyc, open_age AS age, today AS tdy
),

fix_commits AS (
  SELECT
    (commit_ts AT TIME ZONE 'utc')::DATE AS commit_dt,
    LOWER(TRIM(REGEXP_REPLACE(subject, '\s+', ' ', 'g'))) AS fix_key
  FROM {{ ref('stg_git_commits') }}
  WHERE branch != 'master' AND NOT is_plumbing
)

SELECT
  bnd.cycle_start_dt,
  bnd.next_wrap AS cycle_end_dt,
  bnd.is_open_cycle,
  bnd.window_days,
  COUNT(DISTINCT fix.fix_key) FILTER (
    WHERE fix.commit_dt > bnd.cycle_start_dt AND fix.commit_dt <= bnd.early_end
  ) AS distinct_fixes_early,
  CASE
    WHEN bnd.next_wrap IS null THEN null
    ELSE COUNT(DISTINCT fix.fix_key) FILTER (
      WHERE fix.commit_dt > bnd.cycle_start_dt AND fix.commit_dt <= bnd.next_wrap
    )
  END AS distinct_fixes_full
FROM bounded AS bnd
CROSS JOIN fix_commits AS fix
GROUP BY bnd.cycle_start_dt, bnd.next_wrap, bnd.is_open_cycle, bnd.window_days, bnd.early_end
ORDER BY bnd.cycle_start_dt
