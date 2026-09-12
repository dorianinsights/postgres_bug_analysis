-- The computed release calendar must agree with reality: for every scheduled
-- release, the latest release tag within the wrap window before it (the OBSERVED
-- wrap) must fall within a couple of days of a computed calendar wrap Monday.
-- A row here means the schedule rule drifted from what the project actually did.
WITH observed_wraps AS (
  SELECT
    wvs.release_dt,
    MAX(ver.wrap_dt) AS observed_wrap_dt
  FROM {{ ref('int_releases') }} AS wvs
  INNER JOIN {{ ref('int_versions') }} AS ver
    ON ver.wrap_dt BETWEEN wvs.release_dt - {{ var('wrap_tag_window_days') }} AND wvs.release_dt
  WHERE wvs.status = 'shipped' AND NOT wvs.is_out_of_band AND NOT wvs.is_partial_window
  GROUP BY ALL
)

SELECT
  obs.release_dt,
  obs.observed_wrap_dt
FROM observed_wraps AS obs
LEFT JOIN {{ ref('int_release_calendar') }} AS cal
  ON obs.observed_wrap_dt BETWEEN cal.wrap_dt AND cal.wrap_dt + 2
WHERE cal.wrap_dt IS null
