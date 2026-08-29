SELECT
  branch,
  hash AS commit_hash,
  commit_date::DATE AS commit_date,
  COALESCE(subject, '') AS subject,
  is_plumbing::INTEGER = 1 AS is_plumbing,
  COALESCE(ai_credit, '') AS ai_credit
FROM {{ source('scraped', 'git_commits') }}
