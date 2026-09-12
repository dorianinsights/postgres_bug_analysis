WITH per_commit AS (
  SELECT
    commit_hash,
    BOOL_OR(source_list = 'pgsql-bugs') AS has_bugs_thread,
    BOOL_OR(source_list = 'pgsql-hackers') AS has_hackers_thread
  FROM {{ ref('int_commit_discussions') }}
  GROUP BY ALL
)

SELECT
  gcm.commit_hash,
  CASE
    WHEN COALESCE(pcm.has_bugs_thread, false) OR gcm.bug_refs IS NOT null THEN 'pgsql-bugs'
    WHEN COALESCE(pcm.has_hackers_thread, false) THEN 'pgsql-hackers'
    ELSE 'unknown_or_internal'
  END AS origin
FROM {{ ref('int_git_commits') }} AS gcm
LEFT OUTER JOIN per_commit AS pcm ON gcm.commit_hash = pcm.commit_hash
