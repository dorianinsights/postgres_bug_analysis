-- The computed release calendar must agree with reality: for every scheduled
-- wave, the latest release tag within the wrap window before it (the OBSERVED
-- wrap) must fall within a couple of days of a computed calendar wrap Monday.
-- A row here means the schedule rule drifted from what the project actually did.
-- (Inlined here now that the cycle fact uses the computed calendar wraps
-- directly, rather than leaning on the former git_cycle_pace's observed wraps.)
WITH observed_wraps AS (
  SELECT
    wvs.wave_dt,
    MAX((tag.tag_ts AT TIME ZONE 'utc')::DATE) AS observed_wrap_dt
  FROM {{ ref('int_wave_summary') }} AS wvs
  INNER JOIN {{ ref('stg_git_tags') }} AS tag
    ON
      (tag.tag_ts AT TIME ZONE 'utc')::DATE
      BETWEEN wvs.wave_dt - {{ var('wrap_tag_window_days') }} AND wvs.wave_dt
  WHERE NOT wvs.is_out_of_band AND NOT wvs.is_partial_window
  GROUP BY ALL
)

SELECT
  obs.wave_dt,
  obs.observed_wrap_dt
FROM observed_wraps AS obs
LEFT JOIN {{ ref('int_release_calendar') }} AS cal
  ON obs.observed_wrap_dt BETWEEN cal.wrap_dt AND cal.wrap_dt + 2
WHERE cal.wrap_dt IS null
