-- Commit-grain fact: one row per commit (a backpatch is its own commit, with its
-- own hash). Foreign keys into dim_person (author and committer roles), dim_date
-- (commit day), dim_release / dim_version (the release+minor it shipped in), and
-- dim_major (its development line -- the branch, master included). Measures are
-- the representative diff size; origin and the plumbing/AI flags ride along as
-- degenerate attributes. Each person key is resolved by computing the identity
-- node (person_node macro) and joining int_person_map, so it matches
-- dim_person's connected-component resolution. The branch string is no longer
-- stored -- it is dim_major.stable_branch. Grain = commit_hash.
WITH file_stats AS (
  SELECT
    commit_hash,
    COUNT(*)::BIGINT AS file_cnt,
    SUM(COALESCE(lines_added, 0))::BIGINT AS lines_added_sum,
    SUM(COALESCE(lines_deleted, 0))::BIGINT AS lines_deleted_sum
  FROM {{ ref('stg_commit_files') }}
  GROUP BY ALL
)

SELECT
  gcm.commit_hash,
  COALESCE(pmp_a.person_key, {{ unknown_key() }}) AS author_dim_person_key,
  COALESCE(pmp_c.person_key, {{ unknown_key() }}) AS committer_dim_person_key,
  -- the release / minor this commit shipped in, resolved once in
  -- int_commit_versions (branch's major x its cycle window); master and
  -- not-yet-shipped commits have no scheduled release -> Not Applicable
  COALESCE(drl.dim_release_key, {{ not_applicable_key() }}) AS dim_release_key,
  COALESCE(dvr.dim_version_key, {{ not_applicable_key() }}) AS dim_version_key,
  -- the commit's development line (dim_major includes master, so this always
  -- resolves; the COALESCE only guards an unexpected branch)
  COALESCE(dmj.dim_major_key, {{ not_applicable_key() }}) AS dim_major_key,
  -- commit_dt (the UTC calendar day) is the dim_date FK and leads with the other
  -- keys; commit_ts is the full committer instant kept alongside for latency.
  gcm.commit_dt,
  gcm.commit_ts,
  org.origin,
  igc.is_plumbing,
  igc.ai_credit IS NOT null AS has_ai_credit,
  igc.ai_credit,
  COALESCE(fst.file_cnt, 0) AS file_cnt,
  COALESCE(fst.lines_added_sum, 0) AS lines_added_sum,
  COALESCE(fst.lines_deleted_sum, 0) AS lines_deleted_sum,
  gcm.subject
FROM {{ ref('stg_git_commits') }} AS gcm
INNER JOIN {{ ref('int_git_commits') }} AS igc
  ON gcm.branch = igc.branch AND gcm.commit_hash = igc.commit_hash
LEFT JOIN {{ ref('int_commit_versions') }} AS icv
  ON gcm.branch = icv.branch AND gcm.commit_hash = icv.commit_hash
LEFT JOIN {{ ref('int_commit_origins') }} AS org ON gcm.commit_hash = org.commit_hash
LEFT JOIN file_stats AS fst ON gcm.commit_hash = fst.commit_hash
-- surrogate keys resolved from the dims (defined once there) on the mapping's
-- natural keys; a NULL ship_release_dt / version (master, not-yet-shipped) misses
-- and falls through to Not Applicable above. Each dim is 1:1 on its natural key.
LEFT JOIN {{ ref('dim_release') }} AS drl ON icv.ship_release_dt = drl.release_dt
LEFT JOIN {{ ref('dim_version') }} AS dvr ON icv.version = dvr.version
-- the commit's development line (its branch); dim_major carries master too.
LEFT JOIN {{ ref('dim_major') }} AS dmj ON gcm.branch = dmj.stable_branch
LEFT JOIN {{ ref('int_person_map') }} AS pmp_a
  ON pmp_a.node_id = {{ person_node('igc.patch_author_email', 'igc.patch_author_name') }}
LEFT JOIN {{ ref('int_person_map') }} AS pmp_c
  ON pmp_c.node_id = {{ person_node('igc.committer_email', 'igc.committer_name') }}
