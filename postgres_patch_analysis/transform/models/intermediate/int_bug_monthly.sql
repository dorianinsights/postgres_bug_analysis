-- Monthly pgsql-bugs report volume vs acted-upon rate. Lives as a typed
-- intermediate (the bug_reports_monthly mart is a thin ordered SELECT)
-- so the decimal pct column can be tested here — the mart's CSV view
-- re-sniffs without DOUBLE and reads decimals as text.
SELECT
  DATE_TRUNC('month', reported_dt)::DATE AS report_month_dt,
  COUNT(*) AS n_reports,
  SUM(acted_upon) AS n_acted_upon,
  ROUND(SUM(acted_upon) * 100.0 / COUNT(*), 1) AS pct_acted_upon,
  MEDIAN(days_to_commit) AS median_days_to_commit
FROM {{ ref('int_bug_outcomes') }}
GROUP BY DATE_TRUNC('month', reported_dt)
