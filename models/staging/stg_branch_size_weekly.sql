WITH classified AS (
  SELECT
    rbs.branch,
    rbs.commit_hash,
    rbs.subsystem,
    COALESCE(fcr.file_class, 'other') AS file_class,
    CAST(rbs.week_start AS DATE) AS week_start,
    CAST(rbs.code_lines AS BIGINT) AS code_lines,
    CAST(rbs.file_cnt AS BIGINT) AS file_cnt
  FROM {{ ref('raw_branch_size_weekly') }} AS rbs
  LEFT JOIN {{ ref('file_class_rules') }} AS fcr ON rbs.extension = fcr.extension
)

SELECT
  branch,
  commit_hash,
  subsystem,
  file_class,
  week_start,
  SUM(code_lines) AS code_lines,
  SUM(file_cnt) AS file_cnt
FROM classified
GROUP BY branch, commit_hash, subsystem, file_class, week_start
