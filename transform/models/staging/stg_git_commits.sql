-- commit_ts: the full committer timestamp (ISO 8601 with offset), cast
-- strictly to TIMESTAMP WITH TIME ZONE (raises on malformed input).
-- Day-truncation is deliberately NOT done here — consumers truncate at
-- their point of use. body is NULL when the commit message has no body
-- (no empty strings in this layer). author_* is the patch author (%an/%ae);
-- committer_* is who pushed it (%cn/%ce) — the two differ for a committed
-- contributor patch; both feed the person dimension. Derived flags
-- (is_plumbing, ai_credit) live downstream in int_git_commits, not here.
SELECT
  branch,
  hash AS commit_hash,
  commit_ts::TIMESTAMPTZ AS commit_ts,
  NULLIF(TRIM(author_name), '') AS author_name,
  NULLIF(TRIM(author_email), '') AS author_email,
  NULLIF(TRIM(committer_name), '') AS committer_name,
  NULLIF(TRIM(committer_email), '') AS committer_email,
  subject,
  body
FROM {{ ref('raw_git_commits') }}
