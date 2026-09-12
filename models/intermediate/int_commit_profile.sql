WITH profile AS (
  SELECT
    commit_hash,
    COUNT(*)::BIGINT AS file_cnt,
    SUM(COALESCE(lines_added, 0))::BIGINT AS lines_added_sum,
    SUM(COALESCE(lines_deleted, 0))::BIGINT AS lines_deleted_sum,
    MAX(subsystem = 'tests') AS has_test_changes,
    MIN(subsystem = 'docs') AS is_docs_only
  FROM {{ ref('int_commit_files') }}
  GROUP BY ALL
),

votes AS (
  SELECT
    commit_hash,
    subsystem,
    COUNT(*) AS file_cnt,
    SUM(COALESCE(lines_added, 0) + COALESCE(lines_deleted, 0)) AS line_sum
  FROM {{ ref('int_commit_files') }}
  GROUP BY ALL
),

-- most files, then most lines; tests/docs win only when nothing else changed
dominant AS (
  SELECT
    commit_hash,
    subsystem AS dominant_subsystem
  FROM votes
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY commit_hash
    ORDER BY (subsystem IN ('tests', 'docs')) ASC, file_cnt DESC, line_sum DESC, subsystem ASC
  ) = 1
)

SELECT
  prf.commit_hash,
  prf.file_cnt,
  prf.lines_added_sum,
  prf.lines_deleted_sum,
  prf.lines_added_sum + prf.lines_deleted_sum AS churn,
  prf.has_test_changes,
  prf.is_docs_only,
  dom.dominant_subsystem
FROM profile AS prf
INNER JOIN dominant AS dom ON prf.commit_hash = dom.commit_hash
