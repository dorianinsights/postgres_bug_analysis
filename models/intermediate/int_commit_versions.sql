SELECT
  gcm.branch,
  gcm.commit_hash,
  gcm.commit_ts,
  gcm.commit_dt,
  cvs.version,
  cvs.major,
  -- the mapping (tag ancestry) leaves exactly two kinds of commit unmapped:
  -- a released major's stable-branch commits after its latest tag (pending
  -- for the open release) and master after the newest fork
  CASE
    WHEN cvs.minor > 0 THEN 'shipped'
    WHEN cvs.version IS NOT null THEN 'development'
    WHEN gcm.branch != 'master' THEN 'open'
  END AS release_status,
  CASE release_status
    WHEN 'shipped' THEN ver.release_dt
    WHEN 'open' THEN opn.release_dt
  END AS ship_release_dt
FROM {{ ref('int_git_commits') }} AS gcm
LEFT OUTER JOIN {{ ref('stg_commit_versions') }} AS cvs ON gcm.commit_hash = cvs.commit_hash
LEFT OUTER JOIN {{ ref('int_versions') }} AS ver ON cvs.version = ver.version
-- the one open release attaches to every commit
LEFT OUTER JOIN {{ ref('int_releases') }} AS opn ON opn.status = 'open'
