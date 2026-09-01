-- Monthly mailing-list activity per list, with the fix linkage that makes it a
-- leading indicator — an aggregate fact rolled up from fct_messages (the atomic
-- message grain) and conformed on dim_date via month_dt. The full-history
-- companion to fct_list_traffic_weekly_agg. Right-censoring caveat: recent months'
-- threads may not have been cited YET. UTC months.
SELECT
  DATE_TRUNC('month', sent_dt)::DATE AS month_dt,
  list_name,
  COUNT(*) AS message_cnt,
  COUNT(*) FILTER (WHERE is_thread_start) AS thread_start_cnt,
  COUNT(*) FILTER (
    WHERE is_thread_start AND subject LIKE 'BUG #%'
  ) AS form_report_cnt,
  COUNT(*) FILTER (WHERE is_fix_linked) AS fix_linked_message_cnt,
  COUNT(*) FILTER (
    WHERE is_thread_start AND is_fix_linked
  ) AS fix_linked_thread_start_cnt,
  -- share of the month's messages in commit-cited (fix-linked) threads; a ratio,
  -- so DECIMAL not float. The charts consumed this as an inline division before.
  (COUNT(*) FILTER (WHERE is_fix_linked)::DECIMAL(18, 6) / NULLIF(COUNT(*), 0))::DECIMAL(7, 6) AS fix_linked_share
FROM {{ ref('fct_messages') }}
GROUP BY ALL
