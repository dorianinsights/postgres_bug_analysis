-- One row per numbered pgsql-bugs report: was it acted upon (linked to a
-- commit via Discussion: trailer or bug-number mention), and how fast.
-- The classification columns live here rather than in the faces so every
-- report shares one definition. The window buckets come from the
-- latency_windows / thread_size_windows seeds, where each range and its
-- label are defined together (a NULL upper bound is unbounded);
-- days_to_commit_window stays NULL for never-linked reports because the
-- range join finds no row for a NULL days_to_commit.
SELECT
  ibo.bug_number,
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
