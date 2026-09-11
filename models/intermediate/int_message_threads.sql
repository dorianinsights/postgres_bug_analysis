-- Thread identity for every archived message, resolved TRANSITIVELY: each
-- message's direct parent is its In-Reply-To id (else the LAST id in
-- References -- RFC 5322 lists ancestors oldest first, so the last one is the
-- parent), and the thread root is the topmost archived ancestor reached by
-- climbing that chain within the list. Climbing matters: many clients send
-- only the parent in References, so "the first References id" (the former
-- rule) named different roots for different replies to one thread and split
-- pgsql-hackers into ~27.5k fragments instead of ~17.5k threads.
--
--   parent_id        the direct parent's id (NULL: no reply headers at all)
--   root_id          the thread's root: the topmost archived ancestor, or the
--                    earliest-sent one if a malformed header chain forms a cycle
--   is_thread_start  a genuinely new thread: the message has no parent header
--   is_thread_root   the earliest archived message of its thread -- a thread
--                    start, or the archive's first sight of a thread that began
--                    off-archive (a reply to a pre-corpus or private message)
--   is_fix_linked    the thread was eventually cited by a commit Discussion:
--                    trailer (any message of the thread counts, since trailers
--                    usually cite a mid-thread message)
--   earliest_ship_release_dt  the first scheduled minor whose wrap comes
--                    strictly after the send date -- a message sent ON wrap
--                    Monday counts toward the NEXT release (conservative)
-- Grain = (list_name, message_id).
WITH RECURSIVE messages AS (
  SELECT
    list_name,
    message_id,
    sent_ts,
    sent_dt,
    subject,
    -- In-Reply-To is bare in staging, but some clients append a
    -- "(X's message of ...)" comment or a second id: keep the first token.
    -- References: the last bracketed id.
    COALESCE(
      NULLIF(REGEXP_EXTRACT(in_reply_to, '^([^\s<>]+)', 1), ''),
      NULLIF(REGEXP_EXTRACT(reference_ids, '<([^<>\s]+)>[^<]*$', 1), '')
    ) AS parent_id
  FROM {{ ref('stg_list_messages') }}
),

-- climb the parent chain within the list while the parent is archived. UNION
-- (not UNION ALL) dedups rows, so a malformed cycle terminates on its own.
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

-- the root: the topmost archived ancestor (its own parent is absent or not in
-- the archive); the earliest-sent one when a cycle leaves none on top
roots AS (
  SELECT
    anc.list_name,
    anc.message_id,
    anc.ancestor_id AS root_id
  FROM ancestors AS anc
  INNER JOIN messages AS amsg
    ON anc.list_name = amsg.list_name AND anc.ancestor_id = amsg.message_id
  LEFT JOIN messages AS apar
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
  msg.subject,
  msg.parent_id,
  rts.root_id,
  msg.parent_id IS null AS is_thread_start,
  msg.message_id = rts.root_id AS is_thread_root,
  crt.root_id IS NOT null AS is_fix_linked,
  cal.scheduled_release_dt AS earliest_ship_release_dt
FROM messages AS msg
INNER JOIN roots AS rts ON msg.list_name = rts.list_name AND msg.message_id = rts.message_id
LEFT JOIN cited_roots AS crt ON rts.list_name = crt.list_name AND rts.root_id = crt.root_id
ASOF LEFT JOIN {{ ref('int_release_calendar') }} AS cal
  ON msg.sent_dt < cal.wrap_dt
