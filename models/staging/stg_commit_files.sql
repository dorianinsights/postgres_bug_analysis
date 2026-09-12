SELECT
  hash AS commit_hash,
  file_path,
  NULLIF(lines_added, '-')::INTEGER AS lines_added,
  NULLIF(lines_deleted, '-')::INTEGER AS lines_deleted
FROM {{ ref('raw_commit_files') }}
