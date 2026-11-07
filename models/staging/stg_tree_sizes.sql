WITH classified AS (
  SELECT
    rts.commit_hash,
    rts.subsystem,
    COALESCE(fcr.file_class, 'other') AS file_class,
    CAST(rts.code_lines AS BIGINT) AS code_lines,
    CAST(rts.file_cnt AS BIGINT) AS file_cnt
  FROM {{ ref('raw_tree_sizes') }} AS rts
  LEFT OUTER JOIN {{ ref('file_class_rules') }} AS fcr ON rts.extension = fcr.extension
)

SELECT
  commit_hash,
  subsystem,
  file_class,
  CAST(SUM(code_lines) AS BIGINT) AS code_lines,
  CAST(SUM(file_cnt) AS BIGINT) AS file_cnt
FROM classified
GROUP BY ALL
