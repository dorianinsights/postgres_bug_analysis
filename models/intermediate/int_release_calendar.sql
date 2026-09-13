WITH years AS (
  -- from the year before the earliest corpus release tag, so the earliest
  -- corpus release has a prior scheduled cycle, through the horizon year
  SELECT
    UNNEST(
      GENERATE_SERIES(
        YEAR(MIN(wrap_dt)) - 1,
        YEAR({{ as_of_date() }} + INTERVAL {{ var('release_calendar_horizon_months') }} MONTH)
      )
    ) AS release_year
  FROM {{ ref('int_versions') }}
)

SELECT
  {{ scheduled_release_dt('MAKE_DATE(yrs.release_year, mth.release_month, 1)') }} AS scheduled_release_dt,
  DATE_TRUNC('week', scheduled_release_dt)::DATE AS wrap_dt
FROM years AS yrs, UNNEST({{ var('release_months') }}) AS mth (release_month)
WHERE scheduled_release_dt <= {{ as_of_date() }} + INTERVAL {{ var('release_calendar_horizon_months') }} MONTH
