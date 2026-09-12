SELECT
  imt.list_name,
  imt.message_id,
  COALESCE(pmp.person_key, {{ unknown_key() }}) AS sender_dim_person_key,
  -- Not Applicable when the message names no corpus bug (dim_bug conforms to
  -- the corpus window)
  COALESCE(dbg.dim_bug_key, {{ not_applicable_key() }}) AS dim_bug_key,
  -- Not Applicable for pre-corpus targets, which have no dim_release row
  COALESCE(drl.dim_release_key, {{ not_applicable_key() }}) AS ship_dim_release_key,
  imt.sent_dt,
  -- UTC wall-clock as a plain TIMESTAMP, so it reads the same in any session timezone
  (imt.sent_ts AT TIME ZONE 'utc') AS sent_ts,
  imt.root_id,
  imt.is_thread_start,
  imt.is_thread_root,
  imt.is_fix_linked,
  imt.earliest_ship_release_dt,
  imt.subject
FROM {{ ref('int_message_threads') }} AS imt
LEFT JOIN {{ ref('dim_bug') }} AS dbg ON imt.bug_number = dbg.bug_number
LEFT JOIN {{ ref('int_person_map') }} AS pmp
  ON pmp.node_id = {{ person_node('imt.author_email', 'imt.author_name') }}
LEFT JOIN {{ ref('dim_release') }} AS drl ON imt.earliest_ship_release_dt = drl.release_dt
