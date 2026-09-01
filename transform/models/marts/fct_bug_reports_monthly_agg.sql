-- Monthly pgsql-bugs report volume vs acted-upon rate — an aggregate fact
-- rolled up from the bug dimension (dim_bug, the atomic bug grain) and
-- conformed on dim_date via report_month_dt (the first of the month). Recent
-- months are right-censored: fixes for fresh reports haven't landed yet.
SELECT
  DATE_TRUNC('month', reported_dt)::DATE AS report_month_dt,
  COUNT(*) AS report_cnt,
  COUNT(*) FILTER (WHERE is_acted_upon) AS acted_upon_cnt,
  ROUND(COUNT(*) FILTER (WHERE is_acted_upon) * 100.0 / COUNT(*), 1)::DECIMAL(4, 1) AS acted_upon_pct,
  -- MEDIAN of integer day counts is always a multiple of 0.5, so DECIMAL(6,1)
  -- holds it exactly (no floating point)
  MEDIAN(days_to_commit)::DECIMAL(6, 1) AS days_to_commit_median
FROM {{ ref('dim_bug') }}
-- exclude dim_bug's Unknown / Not Applicable special members (bug_number -1/-2)
WHERE bug_number > 0
GROUP BY ALL
