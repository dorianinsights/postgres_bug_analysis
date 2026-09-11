-- The mailing-list text the AI-involvement classifier reads, one per THREAD:
-- the thread's root message (int_message_threads.is_thread_root -- the
-- earliest archived message, the grain of fct_threads), subject plus body,
-- capped at var(ai_involvement_text_cap_chars). A disclosure that an AI found,
-- analyzed or wrote something lives in the first message far more often than
-- in a reply (and the reply population is 12x larger); replies can be added as
-- a separate population later. Every thread on every ingested list is in
-- scope -- no keyword pre-filter. Grain = (list_name, root_message_id).
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
