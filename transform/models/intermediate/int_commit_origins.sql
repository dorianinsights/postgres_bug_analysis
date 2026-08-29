-- Where each corpus commit's work came from: the archive its Discussion:
-- trailers resolve to. Precedence: any pgsql-bugs thread OR a "Bug: #"
-- trailer means the commit traces to a filed bug report; else any
-- pgsql-hackers thread; else unknown_or_internal (no trailer, or a
-- trailer into an archive we don't ingest — other lists, or embargoed
-- security work with no public thread at all). Deliberately 3-valued:
-- the security split of the unknown bucket needs release-note context,
-- so the marts refine unknown_or_internal downstream. Grain =
-- commit_hash (branch-distinct: a backpatch is its own commit).
WITH thread_links AS (
  SELECT
    dsc.commit_hash,
    ths.source_list
  FROM {{ ref('int_commit_discussions') }} AS dsc
  LEFT JOIN {{ ref('int_thread_sources') }} AS ths ON dsc.message_id = ths.message_id
),

per_commit AS (
  SELECT
    commit_hash,
    BOOL_OR(source_list = 'pgsql-bugs') AS has_bugs_thread,
    BOOL_OR(source_list = 'pgsql-hackers') AS has_hackers_thread
  FROM thread_links
  GROUP BY ALL
),

bug_ref_commits AS (
  SELECT DISTINCT commit_hash
  FROM {{ ref('int_commit_bug_refs') }}
)

SELECT DISTINCT
  gcm.commit_hash,
  CASE
    WHEN COALESCE(pcm.has_bugs_thread, false) OR bref.commit_hash IS NOT null
      THEN 'pgsql-bugs'
    WHEN COALESCE(pcm.has_hackers_thread, false) THEN 'pgsql-hackers'
    ELSE 'unknown_or_internal'
  END AS origin
FROM {{ ref('stg_git_commits') }} AS gcm
LEFT JOIN per_commit AS pcm ON gcm.commit_hash = pcm.commit_hash
LEFT JOIN bug_ref_commits AS bref ON gcm.commit_hash = bref.commit_hash
