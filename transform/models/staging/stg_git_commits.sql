-- commit_ts: the full committer timestamp (ISO 8601 with offset), cast
-- strictly to TIMESTAMP WITH TIME ZONE (raises on malformed input).
-- Day-truncation is deliberately NOT done here — consumers truncate at
-- their point of use. body is NULL when the commit message has no body
-- (no empty strings in this layer). Derived flags (is_plumbing,
-- ai_credit) live downstream in int_git_commits, not here.
SELECT
  branch,
  hash AS commit_hash,
  commit_ts::TIMESTAMPTZ AS commit_ts,
  subject,
  body
FROM {{ ref('raw_git_commits') }}
