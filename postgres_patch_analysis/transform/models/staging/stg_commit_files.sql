-- One file touched by one commit (git log --numstat). Line counts are NULL
-- for binary files (git emits "-"); the strict cast raises on anything
-- else malformed. file_path is verbatim, including git's "{old => new}"
-- rename spelling and quoted non-ASCII paths.
SELECT
  hash AS commit_hash,
  file_path,
  NULLIF(lines_added, '-')::INTEGER AS lines_added,
  NULLIF(lines_deleted, '-')::INTEGER AS lines_deleted
FROM {{ ref('raw_commit_files') }}
