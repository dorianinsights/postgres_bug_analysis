-- Commit-grain fact: one row per commit (per branch — a backpatch is its own
-- commit). Foreign keys into dim_person (author and committer roles) and
-- dim_date (commit day); measures are the representative diff size. Origin and
-- the plumbing/AI flags ride along as degenerate attributes. The person keys
-- are built with the same person_key() macro dim_person uses, so they join.
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
  {{ person_key('igc.patch_author_email', 'igc.patch_author_name') }} AS author_person_key,
  {{ person_key('igc.committer_email', 'igc.committer_name') }} AS committer_person_key,
  STRFTIME((gcm.commit_ts AT TIME ZONE 'utc')::DATE, '%Y%m%d')::INTEGER AS commit_date_key,
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
