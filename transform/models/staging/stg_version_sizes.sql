-- Typed codebase-size-per-release: the total source-line count in the tree at
-- each REL_MAJOR_MINOR release tag, with major/minor and the "major.minor"
-- version derived from the tag (matching stg_git_tags). Grain = version.
SELECT
  tag,
  REGEXP_EXTRACT(tag, '^REL_(\d+)_(\d+)$', 1)::INTEGER AS major,
  REGEXP_EXTRACT(tag, '^REL_(\d+)_(\d+)$', 2)::INTEGER AS minor,
  REGEXP_EXTRACT(tag, '^REL_(\d+)_(\d+)$', 1)
  || '.'
  || REGEXP_EXTRACT(tag, '^REL_(\d+)_(\d+)$', 2) AS version,
  code_lines::BIGINT AS code_lines
FROM {{ ref('raw_version_sizes') }}
WHERE REGEXP_FULL_MATCH(tag, 'REL_\d+_\d+')
