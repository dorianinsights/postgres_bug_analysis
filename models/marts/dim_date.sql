WITH all_days AS (
  SELECT
    base.date_day::DATE AS date_day,
    false AS is_synthetic_row
  FROM (
    {{ dbt_date.get_base_dates(
        start_date=var('date_spine_start'),
        end_date=var('date_spine_end')
    ) }}
  ) AS base
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
