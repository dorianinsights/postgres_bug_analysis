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
