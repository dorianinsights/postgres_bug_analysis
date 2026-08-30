-- The fix -> bug-report links: which numbered pgsql-bugs reports each distinct
-- fix traces back to, through its implementing commits (int_fix_commits) —
-- either a Discussion: trailer citing a BUG thread (int_commit_discussions ->
-- int_bug_messages) or a direct "Bug: #NNNNN" ref (int_commit_bug_refs).
-- Restricted to bug numbers that exist in int_bug_reports (the corpus window)
-- so it conforms to dim_bug. Grain = (item_ord, bug_number). Reused by
-- fct_fixes and bridge_fix_bug.
WITH linked AS (
  SELECT DISTINCT
    fcm.group_ord AS item_ord,
    bmg.bug_number
  FROM {{ ref('int_fix_commits') }} AS fcm
  INNER JOIN {{ ref('int_commit_discussions') }} AS dsc ON fcm.commit_hash = dsc.commit_hash
  INNER JOIN {{ ref('int_bug_messages') }} AS bmg ON dsc.message_id = bmg.message_id
  WHERE bmg.bug_number IS NOT null
  UNION
  SELECT DISTINCT
    fcm.group_ord AS item_ord,
    cbr.bug_number
  FROM {{ ref('int_fix_commits') }} AS fcm
  INNER JOIN {{ ref('int_commit_bug_refs') }} AS cbr ON fcm.commit_hash = cbr.commit_hash
)

SELECT DISTINCT
  lnk.item_ord,
  lnk.bug_number
FROM linked AS lnk
INNER JOIN {{ ref('int_bug_reports') }} AS rpt ON lnk.bug_number = rpt.bug_number
