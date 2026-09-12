{% set columns = [
  'dim_bug_key', 'bug_number', 'reporter_dim_person_key', 'reported_dt', 'subject',
  'thread_message_cnt', 'thread_size_window', 'is_acted_upon', 'outcome', 'linked_via',
  'first_commit_dt', 'days_to_commit', 'days_to_commit_window', 'earliest_ship_release_dt',
  'is_synthetic_row',
] %}

SELECT
  {{ dbt_utils.generate_surrogate_key(['rpt.bug_number']) }} AS dim_bug_key,
  rpt.bug_number,
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
  -- the first scheduled minor whose wrap comes strictly after the report
  cal.scheduled_release_dt AS earliest_ship_release_dt,
  false AS is_synthetic_row
FROM {{ ref('int_bug_reports') }} AS rpt
LEFT JOIN {{ ref('int_person_map') }} AS pmp
  ON pmp.node_id = {{ person_node('rpt.reporter_email', 'rpt.reporter_name') }}
LEFT JOIN {{ ref('thread_size_windows') }} AS tsw
  ON {{ in_range('rpt.thread_message_cnt', 'tsw.min_messages', 'tsw.max_messages') }}
LEFT JOIN {{ ref('latency_windows') }} AS ltw
  ON {{ in_range('rpt.days_to_commit', 'ltw.min_days', 'ltw.max_days') }}
ASOF LEFT JOIN {{ ref('int_release_calendar') }} AS cal
  ON rpt.reported_dt < cal.wrap_dt
{{ special_member_rows(
  'dim_bug_key', columns,
  unknown={
    'bug_number': '-1', 'reporter_dim_person_key': unknown_key(), 'reported_dt': past_eternity_dt(),
    'subject': "'(unknown)'", 'is_acted_upon': 'false', 'outcome': "'(unknown)'",
    'earliest_ship_release_dt': past_eternity_dt(),
  },
  not_applicable={
    'bug_number': '-2', 'reporter_dim_person_key': not_applicable_key(), 'reported_dt': past_eternity_dt(),
    'subject': "'(not applicable)'", 'is_acted_upon': 'false', 'outcome': "'(not applicable)'",
    'earliest_ship_release_dt': past_eternity_dt(),
  },
) }}
