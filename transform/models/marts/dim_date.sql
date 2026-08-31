-- Calendar dimension: one row per day from the earliest commit/message in the
-- corpus through the last scheduled release on the calendar (which reaches one
-- release into the future). date_key is a smart YYYYMMDD integer — the facts
-- store it and join here. Grain = one day. -> ../data/derived/dim_date.csv
WITH bounds AS (
  SELECT
    -- floor to the Monday of the earliest data week so weekly/monthly period
    -- aggregates (fct_list_traffic_weekly_agg's week_date_key etc.) always conform here
    DATE_TRUNC('week', LEAST(
      (SELECT MIN((commit_ts AT TIME ZONE 'utc')::DATE) FROM {{ ref('stg_git_commits') }}),
      (SELECT MIN((sent_ts AT TIME ZONE 'utc')::DATE) FROM {{ ref('stg_list_messages') }})
    ))::DATE AS min_dt,
    (SELECT MAX(scheduled_release_dt) FROM {{ ref('int_release_calendar') }}) AS max_dt
),

days AS (
  SELECT UNNEST(GENERATE_SERIES(bounds.min_dt, bounds.max_dt, INTERVAL 1 DAY))::DATE AS date_day
  FROM bounds
)

SELECT
  STRFTIME(date_day, '%Y%m%d')::INTEGER AS date_key,
  date_day,
  YEAR(date_day) AS year_num,
  QUARTER(date_day) AS quarter_num,
  MONTH(date_day) AS month_num,
  MONTHNAME(date_day) AS month_name,
  DAY(date_day) AS day_of_month,
  ISODOW(date_day) AS iso_dow,
  DAYNAME(date_day) AS weekday_name,
  ISODOW(date_day) < 6 AS is_weekday
FROM days
