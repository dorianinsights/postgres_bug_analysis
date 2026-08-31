-- dim_date is built over a FIXED span (var date_spine_start .. date_spine_end)
-- so it depends on no other model. This test is the guard that keeps those
-- static bounds honest: it fails the build if the corpus ever reaches outside
-- the span, so a silent date_key FK gap can't happen -- widen the var and
-- rebuild when it fires. The low bound is week-floored because the weekly
-- aggregates conform on DATE_TRUNC('week', ...) (the Monday must be present);
-- the high bound covers every date the facts and the release calendar reference.
WITH refs AS (
  SELECT (gcm.commit_ts AT TIME ZONE 'utc')::DATE AS dt
  FROM {{ ref('stg_git_commits') }} AS gcm
  UNION ALL
  SELECT (lms.sent_ts AT TIME ZONE 'utc')::DATE
  FROM {{ ref('stg_list_messages') }} AS lms
  UNION ALL
  SELECT cal.scheduled_release_dt
  FROM {{ ref('int_release_calendar') }} AS cal
),

needed AS (
  SELECT
    DATE_TRUNC('week', MIN(refs.dt))::DATE AS min_needed,
    MAX(refs.dt) AS max_needed
  FROM refs
),

span AS (
  SELECT
    MIN(dtd.date_day) AS min_dt,
    MAX(dtd.date_day) AS max_dt
  FROM {{ ref('dim_date') }} AS dtd
)

SELECT
  ndd.min_needed,
  ndd.max_needed,
  spn.min_dt,
  spn.max_dt
FROM needed AS ndd
CROSS JOIN span AS spn
WHERE ndd.min_needed < spn.min_dt OR ndd.max_needed > spn.max_dt
