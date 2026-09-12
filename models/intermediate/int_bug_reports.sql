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
),

outcomes AS (
  SELECT
    lnk.bug_number,
    BOOL_OR(lnk.link_kind = 'discussion') AS has_discussion_link,
    BOOL_OR(lnk.link_kind = 'bug_ref') AS has_bug_ref_link,
    MIN(gcm.commit_dt) AS first_commit_dt
  FROM {{ ref('int_commit_bug_links') }} AS lnk
  INNER JOIN {{ ref('int_git_commits') }} AS gcm ON lnk.commit_hash = gcm.commit_hash
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
  -- the real reporter from the web-form body, else the transport From header
  COALESCE(
    NULLIF(TRIM(REGEXP_EXTRACT(slm.body_text, 'Logged by:\s*(.+)', 1)), ''),
    slm.author_name
  ) AS reporter_name,
  COALESCE(
    NULLIF(TRIM(REGEXP_EXTRACT(slm.body_text, 'Email address:\s*(.+)', 1)), ''),
    slm.author_email
  ) AS reporter_email,
  otc.bug_number IS NOT null AS is_acted_upon,
  CASE
    WHEN otc.has_discussion_link AND otc.has_bug_ref_link THEN 'both'
    WHEN otc.has_discussion_link THEN 'discussion_link'
    WHEN otc.has_bug_ref_link THEN 'bug_ref'
  END AS linked_via,
  otc.first_commit_dt,
  otc.first_commit_dt - roots.reported_dt AS days_to_commit
FROM roots
INNER JOIN threads ON roots.bug_number = threads.bug_number
INNER JOIN {{ ref('stg_list_messages') }} AS slm
  ON roots.root_message_id = slm.message_id AND slm.list_name = 'pgsql-bugs'
LEFT JOIN outcomes AS otc ON roots.bug_number = otc.bug_number
