-- Weekly mailing-list activity per list, with the fix linkage that makes
-- it a leading indicator: how much of each week's traffic belongs to
-- threads that a commit eventually cites. Right-censoring caveat: recent
-- weeks' threads may simply not have been cited YET — fixes land weeks
-- to months after the discussion — so the fix-linked series always sags
-- toward the present. UTC weeks.
SELECT
  DATE_TRUNC('week', sent_ts AT TIME ZONE 'utc')::DATE AS week_dt,
  -- weeks start Monday and wraps ARE Mondays, so every week maps to one
  -- earliest shippable release; the wrap-Monday week itself already
  -- counts toward the next release (messages that day are post-cutoff)
  MIN(earliest_ship_release_dt) AS earliest_ship_release_dt,
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
