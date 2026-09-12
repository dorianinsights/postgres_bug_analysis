SELECT
  branch,
  commit_hash,
  version,
  SPLIT_PART(version, '.', 1)::INTEGER AS major,
  SPLIT_PART(version, '.', 2)::INTEGER AS minor
FROM {{ ref('raw_commit_versions') }}
