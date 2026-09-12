SELECT
  thr.list_name,
  thr.message_id AS root_message_id,
  thr.sent_dt AS root_sent_dt,
  LEFT(
    COALESCE(msg.subject, '') || CHR(10) || COALESCE(msg.body_text, ''),
    {{ var('ai_involvement_text_cap_chars') }}
  ) AS ai_text
FROM {{ ref('int_message_threads') }} AS thr
INNER JOIN {{ ref('stg_list_messages') }} AS msg
  ON thr.list_name = msg.list_name AND thr.message_id = msg.message_id
WHERE thr.is_thread_root
