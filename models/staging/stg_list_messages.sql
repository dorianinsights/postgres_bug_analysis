SELECT
  list_name,
  TRIM(message_id, '<> ') AS message_id,
  sent_ts::TIMESTAMPTZ AS sent_ts,
  {{ utc_date('sent_ts::TIMESTAMPTZ') }} AS sent_dt,
  NULLIF(TRIM(from_name), '') AS author_name,
  NULLIF(TRIM(from_email), '') AS author_email,
  -- collapse folded-header whitespace runs
  NULLIF(TRIM(REGEXP_REPLACE(subject, '\s+', ' ', 'g')), '') AS subject,
  -- the first bare id only: some clients append a comment or a second id
  NULLIF(REGEXP_EXTRACT(in_reply_to, '^\s*<?([^\s<>]+)', 1), '') AS in_reply_to,
  -- the References header's <id> tokens, ancestors oldest first
  NULLIF(REGEXP_EXTRACT_ALL(reference_ids, '<([^<>\s]+)>', 1), []) AS reference_ids,
  NULLIF(body_text, '') AS body_text,
  -- the pgsql-bugs web form gives every report a "BUG #NNNNN:" subject and
  -- replies keep it after "Re:"; the report itself has no "Re:". Read from the
  -- raw header (the subject alias above is shadowed by the raw column), so the
  -- patterns tolerate the whitespace the normalization above collapses.
  CASE
    WHEN list_name = 'pgsql-bugs' THEN NULLIF(REGEXP_EXTRACT(subject, 'BUG\s+#(\d+):', 1), '')::INTEGER
  END AS bug_number,
  list_name = 'pgsql-bugs' AND COALESCE(REGEXP_MATCHES(subject, '^\s*BUG\s+#\d+:'), false) AS has_bug_report_subject,
  -- the web form's structured body names the real reporter; the From header
  -- is the form's own address. Captures stop at the line end.
  CASE
    WHEN list_name = 'pgsql-bugs'
      THEN NULLIF(TRIM(REGEXP_EXTRACT(body_text, 'Logged by:[ \t]*([^\r\n]+)', 1)), '')
  END AS form_reporter_name,
  CASE
    WHEN list_name = 'pgsql-bugs'
      THEN NULLIF(TRIM(REGEXP_EXTRACT(body_text, 'Email address:[ \t]*([^\r\n]+)', 1)), '')
  END AS form_reporter_email
FROM {{ ref('raw_list_messages') }}
