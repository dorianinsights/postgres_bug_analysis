-- commit_ts: the full committer timestamp (ISO 8601 with offset), cast
-- strictly to TIMESTAMP WITH TIME ZONE (raises on malformed input).
-- commit_dt is that instant's UTC calendar day, derived once here (pinned to
-- UTC so the day boundary can't drift with the session timezone) so consumers
-- group by day via a plain column instead of re-truncating; the full-precision
-- commit_ts instant is kept alongside for latency/ordering. body is NULL when the commit message has no body
-- (no empty strings in this layer). author_* is the patch author (%an/%ae);
-- committer_* is who pushed it (%cn/%ce) — the two differ for a committed
-- contributor patch; both feed the person dimension. Derived flags
-- (is_plumbing, ai_credit) live downstream in int_git_commits, not here.
SELECT
  branch,
  hash AS commit_hash,
  commit_ts::TIMESTAMPTZ AS commit_ts,
  (commit_ts::TIMESTAMPTZ AT TIME ZONE 'utc')::DATE AS commit_dt,
  NULLIF(TRIM(author_name), '') AS author_name,
  NULLIF(TRIM(author_email), '') AS author_email,
  NULLIF(TRIM(committer_name), '') AS committer_name,
  NULLIF(TRIM(committer_email), '') AS committer_email,
  subject,
  body
FROM {{ ref('raw_git_commits') }}
