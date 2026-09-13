WITH RECURSIVE messages AS (
  SELECT
    list_name,
    message_id,
    sent_ts,
    sent_dt,
    author_name,
    author_email,
    subject,
    -- the direct parent: In-Reply-To, else the last References id (RFC 5322
    -- lists ancestors oldest first). Derived here, not in staging, where the
    -- typed headers keep their raw names and a lateral reference would be
    -- shadowed by the raw column.
    COALESCE(in_reply_to, reference_ids[-1]) AS parent_id,
    bug_number,
    has_bug_report_subject,
    form_reporter_name,
    form_reporter_email
  FROM {{ ref('stg_list_messages') }}
),

-- climb the parent chain within the list while the parent is archived; UNION
-- (not UNION ALL) dedups, so a malformed cycle terminates on its own
ancestors (list_name, message_id, ancestor_id) AS (
  SELECT
    list_name,
    message_id,
    message_id AS ancestor_id
  FROM messages
  UNION
  SELECT
    anc.list_name,
    anc.message_id,
    par.message_id AS ancestor_id
  FROM ancestors AS anc
  INNER JOIN messages AS cur
    ON anc.list_name = cur.list_name AND anc.ancestor_id = cur.message_id
  INNER JOIN messages AS par
    ON cur.list_name = par.list_name AND cur.parent_id = par.message_id
),

-- the root: the topmost archived ancestor (its own parent is absent or not
-- archived); the earliest-sent one when a cycle leaves none on top
roots AS (
  SELECT
    anc.list_name,
    anc.message_id,
    anc.ancestor_id AS root_id
  FROM ancestors AS anc
  INNER JOIN messages AS amsg
    ON anc.list_name = amsg.list_name AND anc.ancestor_id = amsg.message_id
  LEFT OUTER JOIN messages AS apar
    ON amsg.list_name = apar.list_name AND amsg.parent_id = apar.message_id
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY anc.list_name, anc.message_id
    ORDER BY (apar.message_id IS NOT null) ASC, amsg.sent_ts ASC, amsg.message_id ASC
  ) = 1
),

cited_roots AS (
  SELECT DISTINCT
    rts.list_name,
    rts.root_id
  FROM roots AS rts
  INNER JOIN {{ ref('int_commit_discussions') }} AS dsc ON rts.message_id = dsc.message_id
)

SELECT
  msg.list_name,
  msg.message_id,
  msg.sent_ts,
  msg.sent_dt,
  msg.author_name,
  msg.author_email,
  msg.subject,
  msg.parent_id,
  rts.root_id,
  msg.parent_id IS null AS is_thread_start,
  msg.message_id = rts.root_id AS is_thread_root,
  crt.root_id IS NOT null AS is_fix_linked,
  msg.bug_number,
  -- the report itself: the earliest bare "BUG #NNNNN:" message that starts a
  -- thread (a re-post, or a reply that dropped the "Re:", repeats the
  -- subject), so at most one per bug number
  msg.has_bug_report_subject AND msg.parent_id IS null AND ROW_NUMBER() OVER (
    PARTITION BY msg.bug_number, msg.has_bug_report_subject AND msg.parent_id IS null
    ORDER BY msg.sent_ts ASC, msg.message_id ASC
  ) = 1 AS is_bug_report,
  msg.form_reporter_name,
  msg.form_reporter_email,
  -- a message sent ON wrap Monday counts toward the NEXT release
  cal.scheduled_release_dt AS earliest_ship_release_dt
FROM messages AS msg
INNER JOIN roots AS rts ON msg.list_name = rts.list_name AND msg.message_id = rts.message_id
LEFT OUTER JOIN cited_roots AS crt ON rts.list_name = crt.list_name AND rts.root_id = crt.root_id
ASOF LEFT OUTER JOIN {{ ref('int_release_calendar') }} AS cal
  ON msg.sent_dt < cal.wrap_dt
