SELECT DISTINCT
  fcm.group_ord AS item_ord,
  lnk.bug_number
FROM {{ ref('int_fix_commits') }} AS fcm
INNER JOIN {{ ref('int_commit_bug_links') }} AS lnk ON fcm.commit_hash = lnk.commit_hash
INNER JOIN {{ ref('int_bug_reports') }} AS rpt ON lnk.bug_number = rpt.bug_number
