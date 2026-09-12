SELECT
  branch,
  hash AS commit_hash,
  commit_ts::TIMESTAMPTZ AS commit_ts,
  {{ utc_date('commit_ts::TIMESTAMPTZ') }} AS commit_dt,
  NULLIF(TRIM(author_name), '') AS author_name,
  NULLIF(TRIM(author_email), '') AS author_email,
  NULLIF(TRIM(committer_name), '') AS committer_name,
  NULLIF(TRIM(committer_email), '') AS committer_email,
  subject,
  body
FROM {{ ref('raw_git_commits') }}
