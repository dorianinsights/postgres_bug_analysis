-- (commit_hash, bug_number) wherever a commit message mentions a numbered
-- pgsql-bugs report ("Bug: #17434" trailers and prose "bug #17434" alike)
-- — the second, message-id-free link from fixes back to reports.
WITH refs AS (
  SELECT
    commit_hash,
    UNNEST(REGEXP_EXTRACT_ALL(body, '[Bb]ug:? #(\d+)', 1)) AS bug_ref
  FROM {{ ref('stg_git_commits') }}
  WHERE body IS NOT null
)

SELECT DISTINCT
  commit_hash,
  bug_ref::INTEGER AS bug_number
FROM refs
