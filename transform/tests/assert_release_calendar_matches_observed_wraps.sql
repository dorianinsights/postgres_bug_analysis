-- The computed release calendar must agree with reality: every
-- tag-derived cycle start in git_cycle_pace (the latest release tag
-- within the wrap window before a scheduled wave) must fall within a
-- couple of days of a computed wrap Monday. A row here means the
-- schedule rule drifted from what the project actually did.
SELECT gcp.cycle_start_dt
FROM {{ ref('git_cycle_pace') }} AS gcp
LEFT JOIN {{ ref('int_release_calendar') }} AS cal
  ON gcp.cycle_start_dt BETWEEN cal.wrap_dt AND cal.wrap_dt + 2
WHERE cal.wrap_dt IS null
