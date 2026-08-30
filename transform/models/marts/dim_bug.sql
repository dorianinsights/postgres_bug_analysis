-- Bug-report dimension: one row per numbered pgsql-bugs report. Conforms the
-- bug grain into the star AND folds in what the retired bug_report_outcomes
-- mart computed (outcome label, the thread-size / latency window labels from
-- the seeds, and the earliest release the fix could ship in) so the faces read
-- this one table. reporter -> dim_person (the root message's sender),
-- report day -> dim_date. Grain = bug_number. -> ../data/derived/dim_bug.csv
SELECT
  ibo.bug_number,
  CASE
    WHEN slm.message_id IS NOT null
      THEN {{ person_key('slm.author_email', 'slm.author_name') }}
  END AS reporter_person_key,
  STRFTIME(ibo.reported_dt, '%Y%m%d')::INTEGER AS reported_date_key,
  ibo.reported_dt,
  ibo.subject,
  ibo.thread_message_cnt,
  tsw.label AS thread_size_window,
  ibo.is_acted_upon,
  CASE
    WHEN ibo.is_acted_upon THEN 'linked to a fix commit'
    ELSE 'no linked commit'
  END AS outcome,
  ibo.linked_via,
  ibo.first_commit_dt,
  ibo.days_to_commit,
  ltw.label AS days_to_commit_window,
  -- first scheduled minor whose wrap comes strictly after the report:
  -- the earliest release its fix could ship in
  cal.scheduled_release_dt AS earliest_ship_release_dt
FROM {{ ref('int_bug_outcomes') }} AS ibo
INNER JOIN {{ ref('int_bug_reports') }} AS rpt ON ibo.bug_number = rpt.bug_number
LEFT JOIN {{ ref('stg_list_messages') }} AS slm
  ON rpt.root_message_id = slm.message_id AND slm.list_name = 'pgsql-bugs'
LEFT JOIN {{ ref('thread_size_windows') }} AS tsw
  ON
    ibo.thread_message_cnt >= tsw.min_messages
    AND ibo.thread_message_cnt <= COALESCE(tsw.max_messages, ibo.thread_message_cnt)
LEFT JOIN {{ ref('latency_windows') }} AS ltw
  ON
    ibo.days_to_commit >= ltw.min_days
    AND ibo.days_to_commit <= COALESCE(ltw.max_days, ibo.days_to_commit)
ASOF LEFT JOIN {{ ref('int_release_calendar') }} AS cal
  ON ibo.reported_dt < cal.wrap_dt
