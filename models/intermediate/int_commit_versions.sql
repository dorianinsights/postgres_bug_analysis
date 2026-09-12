WITH open_release AS (
  SELECT release_dt
  FROM {{ ref('int_releases') }}
  WHERE status = 'open'
),

-- majors with a GA tag: only their stable branches carry pending (open) commits
released_majors AS (
  SELECT DISTINCT major
  FROM {{ ref('int_versions') }}
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
  CASE release_status
    WHEN 'shipped' THEN ver.release_dt
    WHEN 'open' THEN (SELECT opn.release_dt FROM open_release AS opn)
  END AS ship_release_dt
FROM {{ ref('int_git_commits') }} AS gcm
LEFT JOIN {{ ref('stg_commit_versions') }} AS cvs ON gcm.commit_hash = cvs.commit_hash
LEFT JOIN {{ ref('int_versions') }} AS ver ON cvs.version = ver.version
LEFT JOIN released_majors AS rmj ON gcm.branch = 'REL_' || rmj.major || '_STABLE'
