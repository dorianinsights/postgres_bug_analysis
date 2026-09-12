SELECT
  list_name,
  TRIM(message_id, '<> ') AS message_id,
  sent_ts::TIMESTAMPTZ AS sent_ts,
  {{ utc_date('sent_ts::TIMESTAMPTZ') }} AS sent_dt,
  NULLIF(TRIM(from_name), '') AS author_name,
  NULLIF(TRIM(from_email), '') AS author_email,
  NULLIF(TRIM(REGEXP_REPLACE(subject, '\s+', ' ', 'g')), '') AS subject,
  NULLIF(TRIM(in_reply_to, '<> '), '') AS in_reply_to,
  NULLIF(TRIM(reference_ids), '') AS reference_ids,
  NULLIF(body_text, '') AS body_text
FROM {{ ref('raw_list_messages') }}
