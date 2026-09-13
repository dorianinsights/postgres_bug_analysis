WITH spine AS (
  -- the release calendar's span: from the start of its first year (before the
  -- earliest corpus commit or message) through its last scheduled release
  SELECT
    DATE_TRUNC('year', MIN(wrap_dt))::DATE AS spine_start,
    MAX(scheduled_release_dt) AS spine_end
  FROM {{ ref('int_release_calendar') }}
),

all_days AS (
  SELECT
    UNNEST(GENERATE_SERIES(spine_start, spine_end, INTERVAL 1 DAY))::DATE AS date_day,
    false AS is_synthetic_row
  FROM spine
  -- the two "eternity" sentinels are synthetic rows just outside the real spine
  UNION ALL
  SELECT DATE '{{ var('past_eternity') }}' AS date_day, true AS is_synthetic_row
  UNION ALL
  SELECT DATE '{{ var('future_eternity') }}' AS date_day, true AS is_synthetic_row
)

SELECT
  all_days.date_day,
  YEAR(all_days.date_day) AS year_num,
  QUARTER(all_days.date_day) AS quarter_num,
  MONTH(all_days.date_day) AS month_num,
  MONTHNAME(all_days.date_day) AS month_name,
  DAY(all_days.date_day) AS day_of_month,
  ISODOW(all_days.date_day) AS iso_dow,
  DAYNAME(all_days.date_day) AS weekday_name,
  ISODOW(all_days.date_day) < 6 AS is_weekday,
  all_days.is_synthetic_row
FROM all_days
