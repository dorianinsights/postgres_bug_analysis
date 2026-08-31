-- Monthly mailing-list activity per list, with the fix linkage that makes it a
-- leading indicator — an aggregate fact rolled up from fct_messages (the atomic
-- message grain) and conformed on dim_date via month_date_key. The full-history
-- companion to fct_list_traffic_weekly_agg. Right-censoring caveat: recent months'
-- threads may not have been cited YET. UTC months.
SELECT
  DATE_TRUNC('month', sent_dt)::DATE AS month_dt,
  STRFTIME(DATE_TRUNC('month', sent_dt), '%Y%m%d')::INTEGER AS month_date_key,
  list_name,
  COUNT(*) AS message_cnt,
  COUNT(*) FILTER (WHERE is_thread_start) AS thread_start_cnt,
  COUNT(*) FILTER (
    WHERE is_thread_start AND subject LIKE 'BUG #%'
  ) AS form_report_cnt,
  COUNT(*) FILTER (WHERE is_fix_linked) AS fix_linked_message_cnt,
  COUNT(*) FILTER (
    WHERE is_thread_start AND is_fix_linked
  ) AS fix_linked_thread_start_cnt
FROM {{ ref('fct_messages') }}
GROUP BY ALL
