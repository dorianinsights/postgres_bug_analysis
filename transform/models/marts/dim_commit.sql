-- Commit dimension: one row per git commit (a backpatch is its own commit, with
-- its own hash) -- the single home for commit-level attributes and the conformed
-- keys resolved once per commit. It replaces the retired commit-grain fact: a
-- commit's MEASURES (churn, file count) are aggregates of its file rows in
-- fct_commit_files, so nothing measured lives here; only descriptors and FKs.
-- Foreign keys into dim_person (author + committer roles), dim_date (commit day),
-- dim_release / dim_version (the release + minor it shipped in) and dim_major (its
-- development line -- master included). branch_scope folds the major lifecycle for
-- churn views (trunk / stable / beta). origin, the plumbing/AI flags, the dominant
-- subsystem and the subject ride along as attributes. Each person key resolves via
-- the identity node (person_node + int_person_map), matching dim_person.
--
-- NO Kimball special members (the deliberate exception, like dim_date): the only
-- fact that references this dimension, fct_commit_files, is BUILT from the commit
-- spine (every file row belongs to a real commit), so its dim_commit_key is
-- mandatory by construction and never resolves to Unknown / Not Applicable.
-- dim_commit_key is a generate_surrogate_key hash of commit_hash, computed ONCE
-- here; fct_commit_files conforms by joining on commit_hash. Grain = commit_hash.
WITH dominant_subsystem AS (
  SELECT
    commit_hash,
    subsystem AS dominant_subsystem
  FROM (
    SELECT
      commit_hash,
      subsystem,
      COUNT(*) AS file_cnt,
      SUM(COALESCE(lines_added, 0) + COALESCE(lines_deleted, 0)) AS line_sum
    FROM {{ ref('int_commit_files') }}
    GROUP BY ALL
  ) AS votes
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY commit_hash
    ORDER BY (subsystem IN ('tests', 'docs')) ASC, file_cnt DESC, line_sum DESC, subsystem ASC
  ) = 1
)

SELECT
  {{ dbt_utils.generate_surrogate_key(['gcm.commit_hash']) }} AS dim_commit_key,
  COALESCE(pmp_a.person_key, {{ unknown_key() }}) AS author_dim_person_key,
  COALESCE(pmp_c.person_key, {{ unknown_key() }}) AS committer_dim_person_key,
  -- the minor this commit shipped in (int_commit_versions -> dim_version by exact
  -- tag ancestry), and its release from that version's row. master and
  -- not-yet-shipped commits miss -> Not Applicable.
  COALESCE(dvr.dim_release_key, {{ not_applicable_key() }}) AS dim_release_key,
  COALESCE(dvr.dim_version_key, {{ not_applicable_key() }}) AS dim_version_key,
  -- the commit's development line (dim_major includes master, so this always
  -- resolves; the COALESCE only guards an unexpected branch)
  COALESCE(dmj.dim_major_key, {{ not_applicable_key() }}) AS dim_major_key,
  gcm.commit_dt,
  gcm.commit_hash,
  gcm.commit_ts,
  -- the major lifecycle folded for churn views
  CASE dmj.lifecycle
    WHEN 'development' THEN 'trunk'
    WHEN 'released' THEN 'stable'
    WHEN 'beta' THEN 'beta'
    ELSE 'other'
  END AS branch_scope,
  org.origin,
  igc.is_plumbing,
  igc.ai_credit IS NOT null AS has_ai_credit,
  igc.ai_credit,
  -- the area this commit mostly touched (weighted vote over its files); 'other'
  -- for an empty commit with no file changes
  COALESCE(dsub.dominant_subsystem, 'other') AS dominant_subsystem,
  gcm.subject
FROM {{ ref('stg_git_commits') }} AS gcm
INNER JOIN {{ ref('int_git_commits') }} AS igc
  ON gcm.branch = igc.branch AND gcm.commit_hash = igc.commit_hash
LEFT JOIN {{ ref('int_commit_versions') }} AS icv
  ON gcm.branch = icv.branch AND gcm.commit_hash = icv.commit_hash
LEFT JOIN {{ ref('int_commit_origins') }} AS org ON gcm.commit_hash = org.commit_hash
LEFT JOIN dominant_subsystem AS dsub ON gcm.commit_hash = dsub.commit_hash
-- resolve the version from int_commit_versions' mapping; dim_release_key and
-- dim_version_key ride along (dim_version is 1:1 on version).
LEFT JOIN {{ ref('dim_version') }} AS dvr ON icv.version = dvr.version
LEFT JOIN {{ ref('dim_major') }} AS dmj ON gcm.branch = dmj.stable_branch
LEFT JOIN {{ ref('int_person_map') }} AS pmp_a
  ON pmp_a.node_id = {{ person_node('igc.patch_author_email', 'igc.patch_author_name') }}
LEFT JOIN {{ ref('int_person_map') }} AS pmp_c
  ON pmp_c.node_id = {{ person_node('igc.committer_email', 'igc.committer_name') }}
