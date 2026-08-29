{{ config(materialized='external', location='../data/derived/bug_reports_monthly.csv', format='csv') }}

SELECT *
FROM {{ ref('int_bug_monthly') }}
ORDER BY report_month_dt
