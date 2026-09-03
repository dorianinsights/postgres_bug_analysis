-- Commit dimension: one row per git commit (a backpatch is its own commit, with
-- its own hash) -- the single home for commit-level attributes and the conformed
-- keys resolved once per commit. It replaces the retired commit-grain fact: a
-- commit's MEASURES (churn, file count) are aggregates of its file rows in
-- fct_commit_files, so nothing measured lives here; only descriptors and FKs.
-- Foreign keys into dim_person (author + committer roles), dim_date (commit day),
-- dim_release / dim_version (the release + minor it shipped in) and dim_major (its
-- development line -- master included). branch_scope is the commit's own
-- lifecycle scope for churn views (trunk / beta / stable -- a stable branch holds
-- both its pre-GA beta work and its backpatch stream, told apart by
-- int_commit_versions). origin, the AI-credit flag, the dominant
-- subsystem and the subject ride along as attributes. Each person key resolves via
-- the identity node (person_node + int_person_map), matching dim_person.
--
-- The fix-commit spine: fix_key (normalized subject, the identity of a committed
-- fix across its backpatches -- COUNT(DISTINCT fix_key) is "distinct fixes") and
-- is_housekeeping (stamps, translations, notes drafting: commits that are not
-- fixes) come from int_git_commits; is_documented / documented_item_ord say
-- whether a release-notes item cites this commit (the int_fix_commits bridge,
-- inverted). dim_release_key resolves through int_commit_versions: exact tag
-- ancestry for shipped commits, and the OPEN release for a released major's
-- stable-branch commits after its latest tag (the pending fix stream) -- so
-- "committed toward the next release" is a plain filter on this key.
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
),

-- the release-notes item citing each commit (the lowest item when a combined
-- commit is annotated under several)
documented AS (
  SELECT
    commit_hash,
    MIN(group_ord) AS documented_item_ord
  FROM {{ ref('int_fix_commits') }}
  WHERE commit_hash IS NOT null
  GROUP BY ALL
)

SELECT
  {{ dbt_utils.generate_surrogate_key(['gcm.commit_hash']) }} AS dim_commit_key,
  COALESCE(pmp_a.person_key, {{ unknown_key() }}) AS author_dim_person_key,
  COALESCE(pmp_c.person_key, {{ unknown_key() }}) AS committer_dim_person_key,
  -- the release this commit shipped in, or is pending for (int_commit_versions
  -- -> int_releases, which mints the key dim_release conforms to). The beta
  -- branch's commits fall through to their version's in_development release
  -- (dim_version's 19.0 row); master misses -> Not Applicable.
  COALESCE(irl.dim_release_key, dvr.dim_release_key, {{ not_applicable_key() }}) AS dim_release_key,
  -- the minor it shipped in (tag ancestry -> dim_version); pending commits have
  -- no tag yet -> Not Applicable
  COALESCE(dvr.dim_version_key, {{ not_applicable_key() }}) AS dim_version_key,
  -- the commit's development line (dim_major includes master, so this always
  -- resolves; the COALESCE only guards an unexpected branch)
  COALESCE(dmj.dim_major_key, {{ not_applicable_key() }}) AS dim_major_key,
  gcm.commit_dt,
  gcm.commit_hash,
  gcm.commit_ts,
  -- the commit's lifecycle scope for churn views, per COMMIT (a stable branch
  -- carries both its pre-GA stabilization and its backpatch stream):
  --   trunk   master
  --   beta    a major's pre-GA work on its stable branch (version M.0), for
  --           every major -- the in-progress one and each released one's
  --           own beta period
  --   stable  the backpatch stream: shipped in, or pending for, a minor
  CASE
    WHEN gcm.branch = 'master' THEN 'trunk'
    WHEN icv.release_status = 'development' THEN 'beta'
    WHEN icv.release_status IN ('shipped', 'open') THEN 'stable'
    ELSE 'other'
  END AS branch_scope,
  org.origin,
  igc.ai_credit IS NOT null AS has_ai_credit,
  igc.ai_credit,
  -- the area this commit mostly touched (weighted vote over its files); 'other'
  -- for an empty commit with no file changes
  COALESCE(dsub.dominant_subsystem, 'other') AS dominant_subsystem,
  gcm.subject,
  igc.fix_key,
  igc.is_housekeeping,
  dfx.documented_item_ord IS NOT null AS is_documented,
  -- the citing release-notes item (fct_fixes.item_ord); NULL when none cites
  -- this commit -- an attribute, not an FK, so no special member stands in
  dfx.documented_item_ord,
  -- no Kimball special members here (built from the commit spine), so every
  -- row is real; the flag exists for uniformity across all dimensions
  false AS is_synthetic_row
FROM {{ ref('stg_git_commits') }} AS gcm
INNER JOIN {{ ref('int_git_commits') }} AS igc
  ON gcm.branch = igc.branch AND gcm.commit_hash = igc.commit_hash
LEFT JOIN {{ ref('int_commit_versions') }} AS icv
  ON gcm.branch = icv.branch AND gcm.commit_hash = icv.commit_hash
LEFT JOIN {{ ref('int_commit_origins') }} AS org ON gcm.commit_hash = org.commit_hash
LEFT JOIN dominant_subsystem AS dsub ON gcm.commit_hash = dsub.commit_hash
LEFT JOIN documented AS dfx ON gcm.commit_hash = dfx.commit_hash
-- the release (shipped or open) from the registry that mints its key, and the
-- shipped minor from dim_version (1:1 on version)
LEFT JOIN {{ ref('int_releases') }} AS irl ON icv.ship_release_dt = irl.release_dt
LEFT JOIN {{ ref('dim_version') }} AS dvr ON icv.version = dvr.version
LEFT JOIN {{ ref('dim_major') }} AS dmj ON gcm.branch = dmj.stable_branch
LEFT JOIN {{ ref('int_person_map') }} AS pmp_a
  ON pmp_a.node_id = {{ person_node('igc.patch_author_email', 'igc.patch_author_name') }}
LEFT JOIN {{ ref('int_person_map') }} AS pmp_c
  ON pmp_c.node_id = {{ person_node('igc.committer_email', 'igc.committer_name') }}
