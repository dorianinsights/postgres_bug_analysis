-- Origin of each distinct DOCUMENTED fix (dedup-group grain): resolved from
-- ALL of the group's annotated commits across branches with the shared
-- resolve_fix_origin precedence -- any commit tracing to pgsql-bugs makes the
-- fix bug-sourced, else any tracing to pgsql-hackers. Fixes with no public
-- trail split by the release notes' CVE mention: unknown_or_internal_security
-- is the expected case (embargoed work on the private security@ list),
-- unknown_or_internal_not_security is the genuinely unsourceable remainder.
-- int_committed_fixes classifies the committed fixes with the same macro.
WITH fix_commit_origins AS (
  SELECT
    fcm.group_ord,
    org.origin
  FROM {{ ref('int_fix_commits') }} AS fcm
  INNER JOIN {{ ref('int_commit_origins') }} AS org ON fcm.commit_hash = org.commit_hash
),

resolved AS (
  SELECT
    group_ord,
    BOOL_OR(origin = 'pgsql-bugs') AS from_bugs,
    BOOL_OR(origin = 'pgsql-hackers') AS from_hackers
  FROM fix_commit_origins
  GROUP BY ALL
)

SELECT
  res.group_ord,
  {{ resolve_fix_origin('res.from_bugs', 'res.from_hackers', 'reps.cves IS NOT null') }} AS origin
FROM resolved AS res
INNER JOIN {{ ref('int_fix_reps') }} AS reps ON res.group_ord = reps.item_ord
