-- Typed commit -> shipped-minor mapping by git tag ancestry, from
-- raw_commit_versions (verbatim strings, no casting needed). One row per
-- (branch, commit) that shipped in a tagged minor. Grain = (branch, commit_hash).
SELECT
  branch,
  commit_hash,
  version
FROM {{ ref('raw_commit_versions') }}
