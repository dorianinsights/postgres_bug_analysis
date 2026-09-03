-- Message-grain fact: one row per archived mailing-list message. Foreign keys
-- into dim_person (sender role), dim_date (send day), and dim_bug (dim_bug_key,
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
  COALESCE(pmp.person_key, {{ unknown_key() }}) AS sender_dim_person_key,
  COALESCE(dbg.dim_bug_key, {{ not_applicable_key() }}) AS dim_bug_key,
  COALESCE(drl.dim_release_key, {{ not_applicable_key() }}) AS ship_dim_release_key,
  imt.sent_dt,
  -- the full send instant in UTC wall-clock (a plain TIMESTAMP, so it always
  -- reads UTC regardless of the session timezone); its ::DATE is sent_dt
  (imt.sent_ts AT TIME ZONE 'utc') AS sent_ts,
  imt.root_id,
  imt.is_thread_start,
  -- the earliest archived message of its thread -- the grain of fct_threads
  imt.is_thread_root,
  imt.is_fix_linked,
  imt.earliest_ship_release_dt,
  imt.subject
FROM {{ ref('int_message_threads') }} AS imt
INNER JOIN {{ ref('stg_list_messages') }} AS slm
  ON imt.list_name = slm.list_name AND imt.message_id = slm.message_id
LEFT JOIN msg_bug AS mbg
  ON imt.message_id = mbg.message_id AND imt.list_name = 'pgsql-bugs'
-- resolve dim_bug_key from the dimension (defined once, there) rather than
-- recomputing the hash; NULL when the message names no corpus bug
LEFT JOIN {{ ref('dim_bug') }} AS dbg ON mbg.bug_number = dbg.bug_number
LEFT JOIN {{ ref('int_person_map') }} AS pmp
  ON pmp.node_id = {{ person_node('slm.author_email', 'slm.author_name') }}
-- the release a thread accrues toward (NULL for pre-corpus targets, which have
-- no dim_release row); the earliest_ship_release_dt degenerate date keeps those
LEFT JOIN {{ ref('dim_release') }} AS drl ON imt.earliest_ship_release_dt = drl.release_dt
