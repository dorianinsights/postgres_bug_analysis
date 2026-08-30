-- Bug-report dimension: one row per numbered pgsql-bugs report, conforming the
-- existing bug_report_outcomes mart into the star — its reporter joins
-- dim_person (the root message's sender) and its report day joins dim_date.
-- Carries the outcome/latency attributes so a bug can be described without the
-- fact. Grain = bug_number. -> ../data/derived/dim_bug.csv
SELECT
  bro.bug_number,
  CASE
    WHEN slm.message_id IS NOT null
      THEN {{ person_key('slm.author_email', 'slm.author_name') }}
  END AS reporter_person_key,
  STRFTIME(bro.reported_dt, '%Y%m%d')::INTEGER AS reported_date_key,
  bro.reported_dt,
  bro.subject,
  bro.thread_message_cnt,
  bro.thread_size_window,
  bro.is_acted_upon,
  bro.outcome,
  bro.linked_via,
  bro.first_commit_dt,
  bro.days_to_commit,
  bro.days_to_commit_window,
  bro.earliest_ship_release_dt
FROM {{ ref('bug_report_outcomes') }} AS bro
INNER JOIN {{ ref('int_bug_reports') }} AS rpt ON bro.bug_number = rpt.bug_number
LEFT JOIN {{ ref('stg_list_messages') }} AS slm
  ON rpt.root_message_id = slm.message_id AND slm.list_name = 'pgsql-bugs'
