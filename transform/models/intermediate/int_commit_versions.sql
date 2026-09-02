-- Which release each commit belongs to -- the SINGLE home for the commit ->
-- version / release mapping (dim_commit, dim_version, int_committed_fixes and
-- int_release_cycles all read it; nothing else re-derives it).
--
-- Shipped commits resolve by EXACT git tag ancestry (stg_commit_versions, built
-- from `git rev-list` between consecutive release tags -- see
-- sources.git.commit_version_records): no date windows, and out-of-band
-- re-releases need zero special-casing (they are ordinary tags).
--
-- A commit on a RELEASED major's stable branch that sits after the branch's
-- latest tag has not shipped yet: it is pending for the OPEN release (the next
-- scheduled minor, from int_releases), so ship_release_dt is that release day
-- and release_status = 'open' (version stays NULL -- no tag exists yet). This
-- is what makes "fixes committed so far toward the next release" the same
-- population, on the same rule, as every shipped release's fixes.
--
-- master and the in-progress major's beta branch never resolve (NULL
-- release_status / ship_release_dt): trunk work is not a minor-release fix, and
-- pre-GA beta stabilization is not a backpatch. (The beta branch's commits do
-- carry the in-progress major's version label, e.g. 19.0, which conforms to
-- dim_version's in-development row but has no release day yet -- so a status
-- is keyed on the RELEASE resolving, not on the version.)
-- Grain = (branch, commit_hash).
WITH open_release AS (
  SELECT release_dt
  FROM {{ ref('int_releases') }}
  WHERE status = 'open'
),

released_branches AS (
  SELECT 'REL_' || major || '_STABLE' AS branch
  FROM {{ ref('stg_major_development') }}
  WHERE dev_status = 'released'
)

SELECT
  gcm.branch,
  gcm.commit_hash,
  gcm.commit_ts,
  gcm.commit_dt,
  cvs.version,
  CASE
    WHEN ver.release_dt IS NOT null THEN 'shipped'
    WHEN rbr.branch IS NOT null THEN 'open'
  END AS release_status,
  CASE
    WHEN ver.release_dt IS NOT null THEN ver.release_dt
    WHEN rbr.branch IS NOT null THEN (SELECT opn.release_dt FROM open_release AS opn)
  END AS ship_release_dt
FROM {{ ref('stg_git_commits') }} AS gcm
LEFT JOIN {{ ref('stg_commit_versions') }} AS cvs
  ON gcm.branch = cvs.branch AND gcm.commit_hash = cvs.commit_hash
LEFT JOIN {{ ref('int_versions') }} AS ver ON cvs.version = ver.version
LEFT JOIN released_branches AS rbr ON gcm.branch = rbr.branch
