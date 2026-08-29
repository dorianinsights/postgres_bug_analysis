-- Monthly pgsql-bugs report volume vs acted-upon rate, folded in from the
-- former int_bug_monthly (which existed only so the decimal pct column
-- could be tested — now that marts are typed tables the mart is testable
-- directly). Recent months are right-censored: fixes for fresh reports
-- haven't landed yet.
SELECT
  DATE_TRUNC('month', reported_dt)::DATE AS report_month_dt,
  COUNT(*) AS report_cnt,
  COUNT(*) FILTER (WHERE is_acted_upon) AS acted_upon_cnt,
  ROUND(COUNT(*) FILTER (WHERE is_acted_upon) * 100.0 / COUNT(*), 1) AS acted_upon_pct,
  MEDIAN(days_to_commit) AS days_to_commit_median
FROM {{ ref('int_bug_outcomes') }}
GROUP BY ALL
