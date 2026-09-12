-- Bug-report dimension: one row per numbered pgsql-bugs report. Conforms the
-- bug grain into the star AND folds in what the retired bug_report_outcomes
-- mart computed (outcome label, the thread-size / latency window labels from
-- the seeds, and the earliest release the fix could ship in) so the faces read
-- this one table. reporter -> dim_person (the root message's sender),
-- report day -> dim_date. Grain = bug_number. -> data/derived/dim_bug.csv
SELECT
  {{ dbt_utils.generate_surrogate_key(['rpt.bug_number']) }} AS dim_bug_key,
  rpt.bug_number,
  -- mandatory FK: fall back to dim_person's Unknown member if unresolved
  COALESCE(pmp.person_key, {{ unknown_key() }}) AS reporter_dim_person_key,
  rpt.reported_dt,
  rpt.subject,
  rpt.thread_message_cnt,
  tsw.label AS thread_size_window,
  rpt.is_acted_upon,
  CASE
    WHEN rpt.is_acted_upon THEN 'linked to a fix commit'
    ELSE 'no linked commit'
  END AS outcome,
  rpt.linked_via,
  rpt.first_commit_dt,
  rpt.days_to_commit,
  ltw.label AS days_to_commit_window,
  -- first scheduled minor whose wrap comes strictly after the report:
  -- the earliest release its fix could ship in
  cal.scheduled_release_dt AS earliest_ship_release_dt,
  false AS is_synthetic_row
FROM {{ ref('int_bug_reports') }} AS rpt
LEFT JOIN {{ ref('int_person_map') }} AS pmp
  ON pmp.node_id = {{ person_node('rpt.reporter_email', 'rpt.reporter_name') }}
LEFT JOIN {{ ref('thread_size_windows') }} AS tsw
  ON
    rpt.thread_message_cnt >= tsw.min_messages
    AND rpt.thread_message_cnt <= COALESCE(tsw.max_messages, rpt.thread_message_cnt)
LEFT JOIN {{ ref('latency_windows') }} AS ltw
  ON
    rpt.days_to_commit >= ltw.min_days
    AND rpt.days_to_commit <= COALESCE(ltw.max_days, rpt.days_to_commit)
ASOF LEFT JOIN {{ ref('int_release_calendar') }} AS cal
  ON rpt.reported_dt < cal.wrap_dt
-- the two Kimball special members
UNION ALL
SELECT
  {{ unknown_key() }} AS dim_bug_key,
  -1 AS bug_number,
  {{ unknown_key() }} AS reporter_dim_person_key,
  DATE '{{ var('past_eternity') }}' AS reported_dt,
  '(unknown)' AS subject,
  null AS thread_message_cnt,
  null AS thread_size_window,
  false AS is_acted_upon,
  '(unknown)' AS outcome,
  null AS linked_via,
  null AS first_commit_dt,
  null AS days_to_commit,
  null AS days_to_commit_window,
  DATE '{{ var('past_eternity') }}' AS earliest_ship_release_dt,
  true AS is_synthetic_row
UNION ALL
SELECT
  {{ not_applicable_key() }} AS dim_bug_key,
  -2 AS bug_number,
  {{ not_applicable_key() }} AS reporter_dim_person_key,
  DATE '{{ var('past_eternity') }}' AS reported_dt,
  '(not applicable)' AS subject,
  null AS thread_message_cnt,
  null AS thread_size_window,
  false AS is_acted_upon,
  '(not applicable)' AS outcome,
  null AS linked_via,
  null AS first_commit_dt,
  null AS days_to_commit,
  null AS days_to_commit_window,
  DATE '{{ var('past_eternity') }}' AS earliest_ship_release_dt,
  true AS is_synthetic_row
