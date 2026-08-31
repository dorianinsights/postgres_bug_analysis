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
)

SELECT
  gcm.branch,
  gcm.commit_hash,
  pmp_a.person_key AS author_dim_person_key,
  pmp_c.person_key AS committer_dim_person_key,
  (gcm.commit_ts AT TIME ZONE 'utc')::DATE AS commit_dt,
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
LEFT JOIN {{ ref('int_person_map') }} AS pmp_a
  ON pmp_a.node_id = {{ person_node('igc.patch_author_email', 'igc.patch_author_name') }}
LEFT JOIN {{ ref('int_person_map') }} AS pmp_c
  ON pmp_c.node_id = {{ person_node('igc.committer_email', 'igc.committer_name') }}
