-- Did each reported bug get acted upon? A report is linked to a commit
-- when EITHER any message of its thread is cited by a Discussion: trailer
-- OR a commit mentions the bug number directly. first_commit_dt is the
-- earliest linked commit (UTC day); days_to_commit the report-to-fix
-- latency. Right-censoring caveat: recent reports may simply not have
-- been acted on YET.
WITH msg_links AS (
  SELECT DISTINCT
    bmg.bug_number,
    dsc.commit_hash
  FROM {{ ref('int_bug_messages') }} AS bmg
  INNER JOIN {{ ref('int_commit_discussions') }} AS dsc ON bmg.message_id = dsc.message_id
  WHERE bmg.bug_number IS NOT null
),

ref_links AS (
  SELECT DISTINCT
    cbr.bug_number,
    cbr.commit_hash
  FROM {{ ref('int_commit_bug_refs') }} AS cbr
  INNER JOIN {{ ref('int_bug_reports') }} AS rpt ON cbr.bug_number = rpt.bug_number
),

link_flags AS (
  SELECT
    rpt.bug_number,
    COUNT(msg.commit_hash) > 0 AS has_discussion_link,
    COUNT(rfl.commit_hash) > 0 AS has_bug_ref_link
  FROM {{ ref('int_bug_reports') }} AS rpt
  LEFT JOIN msg_links AS msg ON rpt.bug_number = msg.bug_number
  LEFT JOIN ref_links AS rfl ON rpt.bug_number = rfl.bug_number
  GROUP BY ALL
),

all_links AS (
  SELECT * FROM msg_links
  UNION
  SELECT * FROM ref_links
),

commit_dates AS (
  SELECT
    lnk.bug_number,
    MIN(gcm.commit_dt) AS first_commit_dt
  FROM all_links AS lnk
  INNER JOIN {{ ref('stg_git_commits') }} AS gcm ON lnk.commit_hash = gcm.commit_hash
  GROUP BY ALL
)

SELECT
  rpt.bug_number,
  rpt.reported_dt,
  rpt.subject,
  rpt.thread_message_cnt,
  cdt.bug_number IS NOT null AS is_acted_upon,
  CASE
    WHEN flg.has_discussion_link AND flg.has_bug_ref_link THEN 'both'
    WHEN flg.has_discussion_link THEN 'discussion_link'
    WHEN flg.has_bug_ref_link THEN 'bug_ref'
  END AS linked_via,
  cdt.first_commit_dt,
  cdt.first_commit_dt - rpt.reported_dt AS days_to_commit
FROM {{ ref('int_bug_reports') }} AS rpt
INNER JOIN link_flags AS flg ON rpt.bug_number = flg.bug_number
LEFT JOIN commit_dates AS cdt ON rpt.bug_number = cdt.bug_number
