-- Typed weekly codebase-size snapshots per stable branch, split by subsystem and
-- file_class. This is where the extension -> file_class classification happens
-- (LEFT JOIN file_class_rules -- the SAME seed the churn side uses via
-- int_commit_files), so it stays in SQL, not the Python source. The raw grain is
-- (branch, week, subsystem, extension); extensions that share a file_class (e.g.
-- .c and .cpp -> source_c) roll up here. code_lines / file_cnt are this slice's
-- share of the tree; the slices of a week sum to the branch's total size.
-- Grain = (branch, week_start, subsystem, file_class).
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
