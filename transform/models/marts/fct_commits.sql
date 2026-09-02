-- Commit-grain fact: one row per commit (per branch — a backpatch is its own
-- commit). Foreign keys into dim_person (author and committer roles) and
-- dim_date (commit day); measures are the representative diff size. Origin and
-- the plumbing/AI flags ride along as degenerate attributes. Each person key is
-- resolved by computing the identity node (person_node macro) and joining
-- int_person_map, so it matches dim_person's connected-component resolution.
-- Grain = (branch, commit_hash). -> ../data/derived/fct_commits.csv
WITH file_stats AS (
  SELECT
    commit_hash,
    COUNT(*)::BIGINT AS file_cnt,
    SUM(COALESCE(lines_added, 0))::BIGINT AS lines_added_sum,
    SUM(COALESCE(lines_deleted, 0))::BIGINT AS lines_deleted_sum
  FROM {{ ref('stg_commit_files') }}
  GROUP BY ALL
),

release_windows AS (
  -- Each scheduled release owns the commits in (previous wrap, its wrap]; a
  -- commit shipped in that release. Boundaries mirror int_release_cycles' cycle
  -- windows, so per-release commit counts reconcile with the fix counts folded
  -- onto dim_release. OOB re-releases and the special members (NULL wrap) are
  -- excluded from the windows.
  SELECT
    dim_release_key,
    COALESCE(LAG(wrap_dt) OVER (ORDER BY wrap_dt), DATE '1900-01-01') AS win_start,
    wrap_dt AS win_end
  FROM {{ ref('dim_release') }}
  WHERE NOT is_out_of_band AND wrap_dt IS NOT null
)

SELECT
  gcm.branch,
  gcm.commit_hash,
  COALESCE(pmp_a.person_key, {{ unknown_key() }}) AS author_dim_person_key,
  COALESCE(pmp_c.person_key, {{ unknown_key() }}) AS committer_dim_person_key,
  -- the release this commit shipped in; master and not-yet-shipped commits have
  -- no scheduled minor release -> Not Applicable
  COALESCE(rwn.dim_release_key, {{ not_applicable_key() }}) AS dim_release_key,
  -- the exact minor this commit shipped in = (its release) x (its branch's
  -- major); resolved ONCE here so consumers join a single surrogate instead of
  -- reconstructing the version from dim_release_key + a major parsed out of the
  -- branch string. Not Applicable for master / not-yet-shipped commits (no
  -- shipped version yet), same as dim_release_key.
  COALESCE(dvr.dim_version_key, {{ not_applicable_key() }}) AS dim_version_key,
  gcm.commit_dt,
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
LEFT JOIN {{ ref('int_commit_origins') }} AS org ON gcm.commit_hash = org.commit_hash
LEFT JOIN file_stats AS fst ON gcm.commit_hash = fst.commit_hash
LEFT JOIN release_windows AS rwn
  ON
    gcm.commit_dt > rwn.win_start
    AND gcm.commit_dt <= rwn.win_end
    AND gcm.branch != 'master'
-- resolve the commit's minor version = its release window x its branch's major.
-- TRY_CAST yields NULL for 'master' (no '_N_'), and rwn.dim_release_key is NULL
-- off a window, so both non-stable and in-flight commits fall through to the
-- COALESCE Not Applicable above. (dim_release_key, major) is unique per shipped
-- minor, so this stays 1:1 -- no fan-out.
LEFT JOIN {{ ref('dim_version') }} AS dvr
  ON
    rwn.dim_release_key = dvr.dim_release_key
    AND TRY_CAST(SPLIT_PART(gcm.branch, '_', 2) AS INTEGER) = dvr.major
LEFT JOIN {{ ref('int_person_map') }} AS pmp_a
  ON pmp_a.node_id = {{ person_node('igc.patch_author_email', 'igc.patch_author_name') }}
LEFT JOIN {{ ref('int_person_map') }} AS pmp_c
  ON pmp_c.node_id = {{ person_node('igc.committer_email', 'igc.committer_name') }}
