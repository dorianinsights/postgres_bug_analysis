-- One row per numbered pgsql-bugs report whose root message falls in the
-- corpus window. reported_dt is the root's day; the thread rollup counts every
-- message carrying the bug number. The reporter is the REAL person from the
-- web-form root body ("Logged by:" / "Email address:") rather than the generic
-- form From header, falling back to that header when the body isn't the
-- standard form (folded in from the former int_bug_reporters). Grain =
-- bug_number.
WITH roots AS (
  SELECT
    bug_number,
    sent_dt AS reported_dt,
    message_id AS root_message_id,
    subject
  FROM {{ ref('int_bug_messages') }}
  WHERE is_root
  QUALIFY ROW_NUMBER() OVER (PARTITION BY bug_number ORDER BY sent_dt ASC, message_id ASC) = 1
),

threads AS (
  SELECT
    bug_number,
    COUNT(*) AS thread_message_cnt,
    MAX(sent_dt) AS last_message_dt
  FROM {{ ref('int_bug_messages') }}
  WHERE bug_number IS NOT null
  GROUP BY ALL
)

SELECT
  roots.bug_number,
  roots.reported_dt,
  roots.root_message_id,
  roots.subject,
  threads.thread_message_cnt,
  threads.last_message_dt,
  slm.sent_ts AS reported_ts,
  COALESCE(
    NULLIF(TRIM(REGEXP_EXTRACT(slm.body_text, 'Logged by:\s*(.+)', 1)), ''),
    slm.author_name
  ) AS reporter_name,
  COALESCE(
    NULLIF(TRIM(REGEXP_EXTRACT(slm.body_text, 'Email address:\s*(.+)', 1)), ''),
    slm.author_email
  ) AS reporter_email
FROM roots
INNER JOIN threads ON roots.bug_number = threads.bug_number
INNER JOIN {{ ref('stg_list_messages') }} AS slm
  ON roots.root_message_id = slm.message_id AND slm.list_name = 'pgsql-bugs'
