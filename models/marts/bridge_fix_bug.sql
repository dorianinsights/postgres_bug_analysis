SELECT DISTINCT
  fcm.group_ord AS item_ord,
  dbg.dim_bug_key
FROM {{ ref('int_fix_commits') }} AS fcm
INNER JOIN {{ ref('int_commit_bug_links') }} AS lnk ON fcm.commit_hash = lnk.commit_hash
INNER JOIN {{ ref('dim_bug') }} AS dbg ON lnk.bug_number = dbg.bug_number
