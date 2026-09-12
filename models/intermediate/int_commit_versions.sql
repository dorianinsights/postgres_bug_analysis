SELECT
  gcm.branch,
  gcm.commit_hash,
  gcm.commit_ts,
  gcm.commit_dt,
  cvs.version,
  CASE
    WHEN NOT ver.is_major_release THEN 'shipped'
    WHEN cvs.version IS NOT null THEN 'development'
    WHEN gav.major IS NOT null THEN 'open'
  END AS release_status,
  CASE release_status
    WHEN 'shipped' THEN ver.release_dt
    WHEN 'open' THEN opn.release_dt
  END AS ship_release_dt
FROM {{ ref('int_git_commits') }} AS gcm
LEFT OUTER JOIN {{ ref('stg_commit_versions') }} AS cvs ON gcm.commit_hash = cvs.commit_hash
LEFT OUTER JOIN {{ ref('int_versions') }} AS ver ON cvs.version = ver.version
-- only a released major's stable branch carries pending (open) commits
LEFT OUTER JOIN {{ ref('int_versions') }} AS gav
  ON gav.is_major_release AND gcm.branch = gav.stable_branch
-- the one open release attaches to every commit
LEFT OUTER JOIN {{ ref('int_releases') }} AS opn ON opn.status = 'open'
