-- commit_ts: the full committer timestamp (ISO 8601 with offset), cast
-- strictly to TIMESTAMP WITH TIME ZONE (raises on malformed input).
-- Day-truncation is deliberately NOT done here — consumers truncate at
-- their point of use (git_cycle_pace and the faces bucket by UTC day).
-- ai_credit is NULL when the commit message credits no AI tool (no empty
-- strings in this layer).
SELECT
  branch,
  hash AS commit_hash,
  commit_ts::TIMESTAMPTZ AS commit_ts,
  subject,
  is_plumbing::INTEGER = 1 AS is_plumbing,
  ai_credit
FROM {{ source('scraped', 'git_commits') }}
