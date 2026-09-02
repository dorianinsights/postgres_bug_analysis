-- Typed weekly codebase-size snapshots per stable branch, from
-- raw_branch_size_weekly (verbatim strings). code_lines is the total source-line
-- count across the code globs; doc_lines (.sgml) and test_lines (src/test) are
-- subsets of it, so implementation lines = code_lines - doc_lines - test_lines.
-- Grain = (branch, week_start).
SELECT
  branch,
  commit_hash,
  CAST(week_start AS DATE) AS week_start,
  CAST(code_lines AS BIGINT) AS code_lines,
  CAST(doc_lines AS BIGINT) AS doc_lines,
  CAST(test_lines AS BIGINT) AS test_lines,
  CAST(file_cnt AS BIGINT) AS file_cnt
FROM {{ ref('raw_branch_size_weekly') }}
