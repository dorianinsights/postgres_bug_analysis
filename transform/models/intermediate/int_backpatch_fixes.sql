-- The committed-but-maybe-unreleased fix stream: one row per stable-branch,
-- non-plumbing commit — the "backpatched fix" definition shared by git_cycle_pace,
-- the fix-projection cycle signals, and the pending-release attribution. fix_key is
-- the normalized subject line; the same fix backpatched to several branches
-- repeats its subject verbatim, so consumers COUNT(DISTINCT fix_key) to get
-- distinct fixes within a window. Grain = (branch, commit_hash).
--
-- Scoped to the RELEASED majors' stable branches (inner join on
-- stg_major_development dev_status = 'released'). This deliberately excludes the
-- in-progress major's stable branch: its post-fork commits are forward beta
-- stabilization of the not-yet-shipped .0, NOT backpatches toward the released
-- majors' quarterly minor cadence — counting them would inflate the pending
-- release, cycle pace, and fix projection.
SELECT
  igc.branch,
  igc.commit_hash,
  igc.commit_ts,
  igc.commit_dt,
  LOWER(TRIM(REGEXP_REPLACE(igc.subject, '\s+', ' ', 'g'))) AS fix_key
FROM {{ ref('int_git_commits') }} AS igc
INNER JOIN {{ ref('stg_major_development') }} AS smd
  ON igc.branch = 'REL_' || smd.major || '_STABLE' AND smd.dev_status = 'released'
WHERE NOT igc.is_plumbing
