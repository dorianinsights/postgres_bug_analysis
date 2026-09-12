-- every commit developed FOR the major: master between fork points plus the
-- branch's pre-GA stabilization
WITH per_major AS (
  SELECT
    major,
    COUNT(*)::BIGINT AS dev_commit_cnt,
    ARG_MIN(commit_hash, commit_ts) AS first_dev_commit_hash,
    MIN(commit_ts) AS first_dev_commit_ts,
    ARG_MAX(commit_hash, commit_ts) AS last_dev_commit_hash,
    MAX(commit_ts) AS last_dev_commit_ts
  FROM {{ ref('int_commit_versions') }}
  WHERE release_status = 'development'
  GROUP BY ALL
),

latest_prerelease AS (
  SELECT
    major,
    ARG_MAX(milestone, tag_ts) AS milestone
  FROM {{ ref('stg_git_tags') }}
  WHERE tag_kind = 'prerelease'
  GROUP BY ALL
)

SELECT
  pmj.major,
  'PG' || pmj.major AS major_label,
  CASE WHEN gam.major IS NOT null THEN 'released' ELSE 'beta' END AS dev_status,
  CASE
    WHEN gam.major IS NOT null THEN 'GA'
    ELSE COALESCE(lpr.milestone, 'pre-beta')
  END AS latest_milestone,
  gam.release_dt AS ga_dt,
  pmj.dev_commit_cnt,
  pmj.first_dev_commit_hash,
  pmj.first_dev_commit_ts,
  {{ utc_date('pmj.first_dev_commit_ts') }} AS first_dev_commit_dt,
  pmj.last_dev_commit_hash,
  pmj.last_dev_commit_ts,
  {{ utc_date('pmj.last_dev_commit_ts') }} AS last_dev_commit_dt
FROM per_major AS pmj
LEFT OUTER JOIN {{ ref('int_versions') }} AS gam ON pmj.major = gam.major AND gam.is_major_release
LEFT OUTER JOIN latest_prerelease AS lpr ON pmj.major = lpr.major
