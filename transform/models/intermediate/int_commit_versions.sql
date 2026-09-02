-- Which shipped minor each commit belongs to, by EXACT git tag ancestry
-- (stg_commit_versions, built from `git rev-list` between consecutive release
-- tags -- see sources.git.commit_version_records). No date windows, no wrap-date
-- heuristic; out-of-band re-releases need zero special-casing (they are ordinary
-- tags). master and open-cycle commits (after the latest tag, not yet released)
-- resolve to NULL. This is the SINGLE home for the commit -> version (and ->
-- ship release) mapping: fct_commits reads it for dim_release_key /
-- dim_version_key, and dim_version reads it (aggregated) for the first/last
-- commit of each version. Grain = (branch, commit_hash).
SELECT
  gcm.branch,
  gcm.commit_hash,
  gcm.commit_ts,
  gcm.commit_dt,
  ver.release_dt AS ship_release_dt,
  cvs.version
FROM {{ ref('stg_git_commits') }} AS gcm
LEFT JOIN {{ ref('stg_commit_versions') }} AS cvs
  ON gcm.branch = cvs.branch AND gcm.commit_hash = cvs.commit_hash
LEFT JOIN {{ ref('int_versions') }} AS ver ON cvs.version = ver.version
