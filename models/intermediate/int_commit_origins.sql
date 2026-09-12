WITH per_commit AS (
  SELECT
    commit_hash,
    BOOL_OR(source_list = 'pgsql-bugs') AS has_bugs_thread,
    BOOL_OR(source_list = 'pgsql-hackers') AS has_hackers_thread
  FROM {{ ref('int_commit_discussions') }}
  GROUP BY ALL
),

-- the release-notes item citing the commit: the lowest item when a combined
-- commit is annotated under several, security if any of them cites a CVE
documented AS (
  SELECT
    fcm.commit_hash,
    MIN(fcm.group_ord) AS documented_item_ord,
    BOOL_OR(reps.cves IS NOT null) AS is_documented_security
  FROM {{ ref('int_fix_commits') }} AS fcm
  INNER JOIN {{ ref('int_fix_reps') }} AS reps ON fcm.group_ord = reps.item_ord
  WHERE fcm.commit_hash IS NOT null
  GROUP BY ALL
)

SELECT
  gcm.commit_hash,
  CASE
    WHEN COALESCE(pcm.has_bugs_thread, false) OR gcm.bug_refs IS NOT null THEN 'pgsql-bugs'
    WHEN COALESCE(pcm.has_hackers_thread, false) THEN 'pgsql-hackers'
    ELSE 'unknown_or_internal'
  END AS origin,
  dfx.documented_item_ord,
  COALESCE(dfx.is_documented_security, false) AS is_documented_security
FROM {{ ref('int_git_commits') }} AS gcm
LEFT OUTER JOIN per_commit AS pcm ON gcm.commit_hash = pcm.commit_hash
LEFT OUTER JOIN documented AS dfx ON gcm.commit_hash = dfx.commit_hash
