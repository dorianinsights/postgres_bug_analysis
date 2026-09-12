WITH bug_refs AS (
  SELECT
    commit_hash,
    UNNEST(REGEXP_EXTRACT_ALL(body, '[Bb]ug:? #(\d+)', 1)) AS bug_ref
  FROM {{ ref('int_git_commits') }}
  WHERE body IS NOT null
)

SELECT DISTINCT
  dsc.commit_hash,
  thr.bug_number,
  'discussion' AS link_kind
FROM {{ ref('int_commit_discussions') }} AS dsc
INNER JOIN {{ ref('int_message_threads') }} AS thr ON dsc.message_id = thr.message_id
WHERE thr.bug_number IS NOT null
UNION ALL
SELECT DISTINCT
  commit_hash,
  bug_ref::INTEGER AS bug_number,
  'bug_ref' AS link_kind
FROM bug_refs
