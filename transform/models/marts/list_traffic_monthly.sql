-- Monthly mailing-list activity per list, with the fix linkage that
-- makes it a leading indicator — the full-history companion to
-- list_traffic_weekly (which serves the recent-window charts). Same
-- right-censoring caveat: recent months' threads may not have been
-- cited YET. UTC months.
SELECT
  DATE_TRUNC('month', sent_ts AT TIME ZONE 'utc')::DATE AS month_dt,
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
FROM {{ ref('int_message_threads') }}
GROUP BY ALL
