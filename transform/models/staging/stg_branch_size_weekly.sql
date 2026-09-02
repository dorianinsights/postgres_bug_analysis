-- Typed weekly codebase-size snapshots per stable branch, split by subsystem,
-- from raw_branch_size_weekly (verbatim strings). code_lines / file_cnt are this
-- subsystem's slice of the tree at the week's end; the subsystems of a week sum
-- to the branch's total size. Grain = (branch, week_start, subsystem).
SELECT
  branch,
  commit_hash,
  subsystem,
  CAST(week_start AS DATE) AS week_start,
  CAST(code_lines AS BIGINT) AS code_lines,
  CAST(file_cnt AS BIGINT) AS file_cnt
FROM {{ ref('raw_branch_size_weekly') }}
