-- Message-grain fact: one row per archived mailing-list message. Foreign keys
-- into dim_person (sender role), dim_date (send day), and dim_bug (bug_number,
-- for pgsql-bugs messages whose "BUG #NNNNN" subject names a corpus report —
-- NULL otherwise); the thread/fix-link attributes ride along. There is
-- deliberately NO CVE FK: CVEs are embargoed on the private security@ list and
-- never appear in these public archives — the message<->CVE path runs through
-- the bug and the fix bridges (bug_number -> dim_bug -> bridge_fix_bug ->
-- fct_fixes -> bridge_fix_cve). A factless transaction fact — the measure is
-- the row count. Grain = (list_name, message_id). -> ../data/derived/fct_messages.csv
WITH msg_bug AS (
  -- one bug per pgsql-bugs message, restricted to bugs that exist in dim_bug
  -- (root in the corpus window) so the FK conforms
  SELECT
    bmg.message_id,
    bmg.bug_number
  FROM {{ ref('int_bug_messages') }} AS bmg
  INNER JOIN {{ ref('int_bug_reports') }} AS rpt ON bmg.bug_number = rpt.bug_number
  WHERE bmg.bug_number IS NOT null
)

SELECT
  imt.list_name,
  imt.message_id,
  {{ person_key('slm.author_email', 'slm.author_name') }} AS sender_person_key,
  STRFTIME((imt.sent_ts AT TIME ZONE 'utc')::DATE, '%Y%m%d')::INTEGER AS sent_date_key,
  mbg.bug_number,
  imt.root_id,
  imt.is_thread_start,
  imt.is_fix_linked,
  imt.earliest_ship_release_dt,
  imt.subject
FROM {{ ref('int_message_threads') }} AS imt
INNER JOIN {{ ref('stg_list_messages') }} AS slm
  ON imt.list_name = slm.list_name AND imt.message_id = slm.message_id
LEFT JOIN msg_bug AS mbg
  ON imt.message_id = mbg.message_id AND imt.list_name = 'pgsql-bugs'
