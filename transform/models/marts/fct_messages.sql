-- Message-grain fact: one row per archived mailing-list message. Foreign keys
-- into dim_person (sender role) and dim_date (send day); the thread/fix-link
-- attributes ride along. A factless transaction fact — the measure is the row
-- count itself (messages sent). Grain = (list_name, message_id).
-- -> ../data/derived/fct_messages.csv
SELECT
  imt.list_name,
  imt.message_id,
  {{ person_key('slm.author_email', 'slm.author_name') }} AS sender_person_key,
  STRFTIME((imt.sent_ts AT TIME ZONE 'utc')::DATE, '%Y%m%d')::INTEGER AS sent_date_key,
  imt.root_id,
  imt.is_thread_start,
  imt.is_fix_linked,
  imt.earliest_ship_release_dt,
  imt.subject
FROM {{ ref('int_message_threads') }} AS imt
INNER JOIN {{ ref('stg_list_messages') }} AS slm
  ON imt.list_name = slm.list_name AND imt.message_id = slm.message_id
