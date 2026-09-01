-- Thread identity for every archived message: the root message id,
-- resolved from the References header (RFC 5322 lists ancestors oldest
-- first, so the first bracketed id is the thread root). A message with
-- no References falls back to In-Reply-To (short reply chains that skip
-- References), then to itself — those are the thread starts.
-- is_fix_linked marks messages whose thread was eventually cited by a
-- commit Discussion: trailer (any message of the thread counts, since
-- trailers usually cite a mid-thread message). earliest_ship_release_dt
-- is the first scheduled minor whose wrap comes strictly after the
-- message's UTC send date — a message sent ON wrap Monday is counted
-- toward the NEXT release (conservative).
WITH resolved AS (
  SELECT
    list_name,
    message_id,
    sent_ts,
    sent_dt,
    subject,
    COALESCE(
      TRIM(REGEXP_EXTRACT(reference_ids, '<([^>]+)>', 1)),
      TRIM(in_reply_to),
      message_id
    ) AS root_id,
    in_reply_to IS null AND reference_ids IS null AS is_thread_start
  FROM {{ ref('stg_list_messages') }}
),

cited_roots AS (
  SELECT DISTINCT res.root_id
  FROM resolved AS res
  INNER JOIN {{ ref('int_commit_discussions') }} AS dsc ON res.message_id = dsc.message_id
)

SELECT
  res.list_name,
  res.message_id,
  res.sent_ts,
  res.sent_dt,
  res.subject,
  res.root_id,
  res.is_thread_start,
  crt.root_id IS NOT null AS is_fix_linked,
  cal.scheduled_release_dt AS earliest_ship_release_dt
FROM resolved AS res
LEFT JOIN cited_roots AS crt ON res.root_id = crt.root_id
ASOF LEFT JOIN {{ ref('int_release_calendar') }} AS cal
  ON res.sent_dt < cal.wrap_dt
