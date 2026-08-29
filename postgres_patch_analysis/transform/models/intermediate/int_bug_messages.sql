-- pgsql-bugs messages tagged with the bug number their subject carries.
-- Thread membership is by bug number: the form gives every report a
-- "BUG #NNNNN:" subject and replies keep it after "Re:". is_root marks
-- the report itself (subject starts with the tag — no Re:).
SELECT
  message_id,
  (sent_ts AT TIME ZONE 'utc')::DATE AS sent_dt,
  author_name,
  subject,
  NULLIF(REGEXP_EXTRACT(subject, 'BUG #(\d+):', 1), '')::INTEGER AS bug_number,
  -- a subject-less message can't carry the bug tag, so NULL subject = FALSE
  COALESCE(REGEXP_MATCHES(subject, '^BUG #\d+:'), false) AS is_root
FROM {{ ref('stg_list_messages') }}
WHERE list_name = 'pgsql-bugs'
