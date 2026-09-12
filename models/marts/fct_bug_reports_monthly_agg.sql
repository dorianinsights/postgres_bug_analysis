SELECT
  DATE_TRUNC('month', reported_dt)::DATE AS report_month_dt,
  COUNT(*) AS report_cnt,
  COUNT(*) FILTER (WHERE is_acted_upon) AS acted_upon_cnt,
  ROUND(acted_upon_cnt * 100.0 / report_cnt, 1)::DECIMAL(4, 1) AS acted_upon_pct,
  -- a median of integer day counts is a multiple of 0.5, so DECIMAL(6,1) holds it exactly
  MEDIAN(days_to_commit)::DECIMAL(6, 1) AS days_to_commit_median
FROM {{ ref('dim_bug') }}
WHERE NOT is_synthetic_row
GROUP BY report_month_dt
