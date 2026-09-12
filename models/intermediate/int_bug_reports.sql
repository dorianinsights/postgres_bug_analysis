WITH threads AS (
  SELECT
    bug_number,
    COUNT(*) AS thread_message_cnt,
    MAX(sent_dt) AS last_message_dt
  FROM {{ ref('int_message_threads') }}
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
  rpt.bug_number,
  rpt.sent_dt AS reported_dt,
  rpt.message_id AS root_message_id,
  rpt.subject,
  thr.thread_message_cnt,
  thr.last_message_dt,
  rpt.sent_ts AS reported_ts,
  -- the real reporter from the web-form body, else the transport From header
  COALESCE(rpt.form_reporter_name, rpt.author_name) AS reporter_name,
  COALESCE(rpt.form_reporter_email, rpt.author_email) AS reporter_email,
  otc.bug_number IS NOT null AS is_acted_upon,
  CASE
    WHEN otc.has_discussion_link AND otc.has_bug_ref_link THEN 'both'
    WHEN otc.has_discussion_link THEN 'discussion_link'
    WHEN otc.has_bug_ref_link THEN 'bug_ref'
  END AS linked_via,
  otc.first_commit_dt,
  otc.first_commit_dt - reported_dt AS days_to_commit
FROM {{ ref('int_message_threads') }} AS rpt
INNER JOIN threads AS thr ON rpt.bug_number = thr.bug_number
LEFT OUTER JOIN outcomes AS otc ON rpt.bug_number = otc.bug_number
WHERE rpt.is_bug_report
