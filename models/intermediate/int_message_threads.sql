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
    -- every id the headers name, nearest first: In-Reply-To, then the
    -- References chain newest to oldest (a missing header is a NULL entry)
    LIST_CONCAT([in_reply_to], LIST_REVERSE(reference_ids)) AS header_ids,
    bug_number,
    has_bug_report_subject,
    form_reporter_name,
    form_reporter_email
  FROM {{ ref('stg_list_messages') }}
),

-- the report of each numbered bug: the earliest bare "BUG #NNNNN:" message
-- with no reply header (a re-post, or a reply that dropped the "Re:", repeats
-- the subject), at most one per bug number
bug_reports AS (
  SELECT
    list_name,
    message_id,
    bug_number
  FROM messages
  WHERE has_bug_report_subject AND parent_id IS null
  QUALIFY ROW_NUMBER() OVER (PARTITION BY bug_number ORDER BY sent_ts ASC, message_id ASC) = 1
),

-- the nearest id the headers name that is archived on the same list, so a
-- reply to an off-list or pre-archive message still joins its thread through
-- an earlier ancestor its References carry (JWZ threading's chain)
archived_header_parents AS (
  SELECT
    msg.list_name,
    msg.message_id,
    ARG_MIN(par.message_id, LIST_POSITION(msg.header_ids, par.message_id)) AS archived_parent_id
  FROM messages AS msg
  CROSS JOIN UNNEST(msg.header_ids) AS hdr (candidate_id)
  INNER JOIN messages AS par
    ON msg.list_name = par.list_name AND hdr.candidate_id = par.message_id
  WHERE par.message_id != msg.message_id
  GROUP BY ALL
),

-- the thread parent: the nearest archived header id; else, for a pgsql-bugs
-- message naming a bug, that bug's report; else the header parent as is (an
-- unarchived id roots the message's own thread; NULL with no header)
threaded AS (
  SELECT
    msg.*,
    COALESCE(ahp.archived_parent_id, bgr.message_id, msg.parent_id) AS thread_parent_id
  FROM messages AS msg
  LEFT OUTER JOIN archived_header_parents AS ahp
    ON msg.list_name = ahp.list_name AND msg.message_id = ahp.message_id
  LEFT OUTER JOIN bug_reports AS bgr
    ON
      msg.list_name = bgr.list_name
      AND msg.bug_number = bgr.bug_number
      AND msg.message_id != bgr.message_id
),

-- climb the thread-parent chain within the list while the parent is archived;
-- UNION (not UNION ALL) dedups, so a malformed cycle terminates on its own
ancestors (list_name, message_id, ancestor_id) AS (
  SELECT
    list_name,
    message_id,
    message_id AS ancestor_id
  FROM threaded
  UNION
  SELECT
    anc.list_name,
    anc.message_id,
    par.message_id AS ancestor_id
  FROM ancestors AS anc
  INNER JOIN threaded AS cur
    ON anc.list_name = cur.list_name AND anc.ancestor_id = cur.message_id
  INNER JOIN threaded AS par
    ON cur.list_name = par.list_name AND cur.thread_parent_id = par.message_id
),

-- the root: the topmost archived ancestor (its own thread parent is absent or
-- not archived); the earliest-sent one when a cycle leaves none on top
roots AS (
  SELECT
    anc.list_name,
    anc.message_id,
    anc.ancestor_id AS root_id
  FROM ancestors AS anc
  INNER JOIN threaded AS amsg
    ON anc.list_name = amsg.list_name AND anc.ancestor_id = amsg.message_id
  LEFT OUTER JOIN threaded AS apar
    ON amsg.list_name = apar.list_name AND amsg.thread_parent_id = apar.message_id
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
  msg.thread_parent_id,
  rts.root_id,
  -- a new thread: nothing to attach it to (no reply header, and no bug report
  -- to join); a reply whose parent is unarchived roots its thread, but is not new
  msg.thread_parent_id IS null AS is_thread_start,
  msg.message_id = rts.root_id AS is_thread_root,
  crt.root_id IS NOT null AS is_fix_linked,
  msg.bug_number,
  bgr.message_id IS NOT null AS is_bug_report,
  msg.form_reporter_name,
  msg.form_reporter_email,
  -- a message sent ON wrap Monday counts toward the NEXT release
  cal.scheduled_release_dt AS earliest_ship_release_dt
FROM threaded AS msg
INNER JOIN roots AS rts ON msg.list_name = rts.list_name AND msg.message_id = rts.message_id
LEFT OUTER JOIN bug_reports AS bgr ON msg.list_name = bgr.list_name AND msg.message_id = bgr.message_id
LEFT OUTER JOIN cited_roots AS crt ON rts.list_name = crt.list_name AND rts.root_id = crt.root_id
ASOF LEFT OUTER JOIN {{ ref('int_release_calendar') }} AS cal
  ON msg.sent_dt < cal.wrap_dt
