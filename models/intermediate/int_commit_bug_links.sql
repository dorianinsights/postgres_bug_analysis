SELECT DISTINCT
  commit_hash,
  bug_number,
  'discussion' AS link_kind
FROM {{ ref('int_commit_discussions') }}
WHERE bug_number IS NOT null
UNION ALL
SELECT
  gcm.commit_hash,
  bug_ref.bug_number,
  'bug_ref' AS link_kind
FROM {{ ref('int_git_commits') }} AS gcm,
  UNNEST(gcm.bug_refs) AS bug_ref (bug_number)
