SELECT
  branch,
  commit_hash,
  version
FROM {{ ref('raw_commit_versions') }}
