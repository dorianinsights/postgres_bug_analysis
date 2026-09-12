-- Which version each commit belongs to -- the SINGLE home for the commit ->
-- version / release mapping, trunk included (dim_commit, dim_version,
-- int_committed_fixes, int_major_development and int_release_cycles all read
-- it; nothing else re-derives it).
--
-- version comes from stg_commit_versions (EXACT git tag ancestry, see
-- sources.git.commit_version_records): a shipped minor M.N for the backpatch
-- stream, or M.0 for the major's development -- master's commits between two
-- consecutive fork points and the stable branch's pre-GA stabilization. It is
-- NULL for a released major's stable-branch commits after the branch's latest
-- tag (pending) and for master's commits after the newest fork (the next,
-- not-yet-branched major).
--
-- release_status folds that into the lifecycle of the RELEASE the commit counts
-- toward:
--   shipped      a minor that has shipped (version M.N, N > 0); ship_release_dt
--                is its release day
--   open         pending for the OPEN release: a released major's stable-branch
--                commit after the branch's latest tag; ship_release_dt is the
--                next scheduled release day (int_releases); version stays NULL
--   development  pre-GA work on a major (version M.0, on master or its branch):
--                not a minor-release fix, so no ship_release_dt
--   NULL         master after the newest fork
-- This is what makes "fixes committed so far toward the next release" the same
-- population, on the same rule, as every shipped release's fixes. The in-progress
-- major's branch commits (e.g. 19.0) are 'development' like every major's
-- pre-GA commits: 19.0 conforms to dim_version's in-development row but has no
-- release day yet, so status keys on the tag-registered minor, not the version.
-- Grain = (branch, commit_hash).
WITH open_release AS (
  SELECT release_dt
  FROM {{ ref('int_releases') }}
  WHERE status = 'open'
),

-- majors with a GA tag: only their stable branches carry pending (open) commits
released_majors AS (
  SELECT DISTINCT major
  FROM {{ ref('stg_git_tags') }}
  WHERE minor = 0
)

SELECT
  gcm.branch,
  gcm.commit_hash,
  gcm.commit_ts,
  gcm.commit_dt,
  cvs.version,
  CASE
    WHEN ver.minor > 0 THEN 'shipped'
    WHEN cvs.version IS NOT null THEN 'development'
    WHEN rmj.major IS NOT null THEN 'open'
  END AS release_status,
  CASE
    WHEN ver.minor > 0 THEN ver.release_dt
    WHEN cvs.version IS null AND rmj.major IS NOT null
      THEN (SELECT opn.release_dt FROM open_release AS opn)
  END AS ship_release_dt
FROM {{ ref('int_git_commits') }} AS gcm
LEFT JOIN {{ ref('stg_commit_versions') }} AS cvs
  ON gcm.branch = cvs.branch AND gcm.commit_hash = cvs.commit_hash
LEFT JOIN {{ ref('int_versions') }} AS ver ON cvs.version = ver.version
LEFT JOIN released_majors AS rmj ON gcm.branch = 'REL_' || rmj.major || '_STABLE'
