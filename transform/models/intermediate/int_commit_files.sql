-- One row per file touched by one commit (stg_commit_files), classified two ways:
-- by DIRECTORY into a subsystem (subsystem_rules -- the same taxonomy fct_fixes /
-- fct_branch_size_weekly use, lowest match_order wins, 'other' fallback) and by
-- EXTENSION into a file_class (file_class_rules -- what KIND of file it is). Where
-- a change lives vs what kind of file it is. The per-commit area signal:
-- fct_commits reads it for dominant_subsystem, and churn-by-area aggregates roll
-- it up. Line counts are NULL for binary files (git numstat emits '-'), so binary
-- churn is never counted. Grain = (commit_hash, file_path).
WITH file_rules AS (
  SELECT
    cfl.commit_hash,
    cfl.file_path,
    MIN(rules.match_order) AS match_order
  FROM {{ ref('stg_commit_files') }} AS cfl
  INNER JOIN {{ ref('subsystem_rules') }} AS rules
    ON REGEXP_MATCHES(cfl.file_path, rules.pattern)
  GROUP BY ALL
)

SELECT
  cfl.commit_hash,
  cfl.file_path,
  COALESCE(rules.subsystem, 'other') AS subsystem,
  COALESCE(fcr.file_class, 'other') AS file_class,
  cfl.lines_added,
  cfl.lines_deleted
FROM {{ ref('stg_commit_files') }} AS cfl
LEFT JOIN file_rules AS fru
  ON cfl.commit_hash = fru.commit_hash AND cfl.file_path = fru.file_path
LEFT JOIN {{ ref('subsystem_rules') }} AS rules ON fru.match_order = rules.match_order
LEFT JOIN {{ ref('file_class_rules') }} AS fcr
  ON LOWER(REGEXP_EXTRACT(cfl.file_path, '\.([A-Za-z0-9]+)$', 1)) = fcr.extension
