-- The committed-but-maybe-unreleased fix stream: one row per stable-branch,
-- non-plumbing commit — the "backpatched fix" definition shared by git_cycle_pace,
-- the fix-projection cycle signals, and the pending-release attribution. fix_key is
-- the normalized subject line; the same fix backpatched to several branches
-- repeats its subject verbatim, so consumers COUNT(DISTINCT fix_key) to get
-- distinct fixes within a window. Grain = (branch, commit_hash).
SELECT
  branch,
  commit_hash,
  commit_ts,
  commit_dt,
  LOWER(TRIM(REGEXP_REPLACE(subject, '\s+', ' ', 'g'))) AS fix_key
FROM {{ ref('int_git_commits') }}
WHERE branch != 'master' AND NOT is_plumbing
