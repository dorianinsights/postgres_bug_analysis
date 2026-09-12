WITH links AS (
  SELECT
    gcm.commit_hash,
    msg_ref.message_id
  FROM {{ ref('int_git_commits') }} AS gcm,
    UNNEST(gcm.discussion_refs) AS msg_ref (message_id)
)

SELECT
  lnk.commit_hash,
  lnk.message_id,
  -- pgsql-bugs wins a cross-post: citing a BUG thread means the work traces to a filed report
  CASE
    WHEN BOOL_OR(msg.list_name = 'pgsql-bugs') THEN 'pgsql-bugs'
    ELSE MIN(msg.list_name)
  END AS source_list,
  -- the BUG # report the cited message belongs to (only its pgsql-bugs copy carries it)
  MAX(msg.bug_number) AS bug_number
FROM links AS lnk
LEFT OUTER JOIN {{ ref('stg_list_messages') }} AS msg ON lnk.message_id = msg.message_id
GROUP BY lnk.commit_hash, lnk.message_id
