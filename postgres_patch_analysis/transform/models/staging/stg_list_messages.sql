-- One archived mailing-list message, typed from the mbox-decoded raw
-- layer. Message ids drop their transport angle brackets — the bare form
-- is the canonical identity that commit Discussion trailers use. sent_ts
-- comes from each message's own Date header (full seconds, original UTC
-- offset preserved in the ISO string) and lands as TIMESTAMPTZ; the
-- strict cast raises on malformed values. Day-truncation happens
-- downstream at the point of use. Subjects keep their decoded text but
-- collapse folded-header whitespace runs.
SELECT
  list_name,
  TRIM(message_id, '<> ') AS message_id,
  sent_ts::TIMESTAMPTZ AS sent_ts,
  NULLIF(TRIM(from_name), '') AS author_name,
  NULLIF(TRIM(from_email), '') AS author_email,
  NULLIF(TRIM(REGEXP_REPLACE(subject, '\s+', ' ', 'g')), '') AS subject,
  NULLIF(TRIM(in_reply_to, '<> '), '') AS in_reply_to,
  NULLIF(TRIM(reference_ids), '') AS reference_ids,
  NULLIF(body_text, '') AS body_text
FROM {{ ref('raw_list_messages') }}
