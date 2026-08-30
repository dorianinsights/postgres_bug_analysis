-- The REAL reporter of each pgsql-bugs report. The web form posts every report
-- from a generic From header ("PG Bug reporting form" <noreply@postgresql.org>),
-- and the actual person is in the body's "Logged by:" / "Email address:" lines.
-- So the reporter is parsed from the root message body, falling back to the
-- root's From header when the body isn't the standard form. reported_ts is the
-- root's send time (for first/last-seen in the person dimension).
-- Grain = bug_number.
WITH root_msgs AS (
  SELECT
    rpt.bug_number,
    slm.author_name AS from_name,
    slm.author_email AS from_email,
    slm.sent_ts,
    slm.body_text
  FROM {{ ref('int_bug_reports') }} AS rpt
  INNER JOIN {{ ref('stg_list_messages') }} AS slm
    ON rpt.root_message_id = slm.message_id AND slm.list_name = 'pgsql-bugs'
)

SELECT
  bug_number,
  COALESCE(
    NULLIF(TRIM(REGEXP_EXTRACT(body_text, 'Logged by:\s*(.+)', 1)), ''),
    from_name
  ) AS reporter_name,
  COALESCE(
    NULLIF(TRIM(REGEXP_EXTRACT(body_text, 'Email address:\s*(.+)', 1)), ''),
    from_email
  ) AS reporter_email,
  sent_ts AS reported_ts
FROM root_msgs
