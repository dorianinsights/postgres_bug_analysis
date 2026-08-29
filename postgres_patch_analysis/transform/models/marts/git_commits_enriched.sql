{{ config(materialized='external', location='../data/derived/git_commits_enriched.csv', format='csv') }}

-- Commit-grain export for the faces: UTC-day grain (the mart is the point
-- of use for day-truncation) plus the flags derived in int_git_commits.
-- The body stays in raw/staging — the faces don't need it.
SELECT
  branch,
  commit_hash,
  (commit_ts AT TIME ZONE 'utc')::DATE AS commit_dt,
  subject,
  is_plumbing::INTEGER AS is_plumbing,
  ai_credit
FROM {{ ref('int_git_commits') }}
ORDER BY branch, commit_dt, commit_hash
