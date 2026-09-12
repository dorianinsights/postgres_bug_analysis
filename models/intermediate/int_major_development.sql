-- Per-major feature-development activity, an AGGREGATE of the commit -> version
-- mapping rather than a separate git walk: every commit whose version is the
-- major's .0 (int_commit_versions release_status = 'development') -- master
-- between the previous major's fork point and this one's, plus the stable
-- branch's pre-GA stabilization -- which is exactly `git rev-list
-- REL_(M-1)_0..REL_M_0` (or ..HEAD for the in-progress major). dev_status comes
-- from the GA tag (stg_git_tags) and latest_milestone from the newest BETA/RC
-- tag (stg_git_prerelease_tags) while the major is in beta. Covers every major
-- with a stable branch at/above the corpus floor, released AND in-progress.
-- Replaces raw_major_development / stg_major_development. Grain = major.
WITH dev_commits AS (
  SELECT
    SPLIT_PART(version, '.', 1)::INTEGER AS major,
    commit_hash,
    commit_ts
  FROM {{ ref('int_commit_versions') }}
  WHERE release_status = 'development'
),

per_major AS (
  SELECT
    major,
    COUNT(*)::BIGINT AS dev_commit_cnt,
    ARG_MIN(commit_hash, commit_ts) AS first_dev_commit_hash,
    MIN(commit_ts) AS first_dev_commit_ts,
    ARG_MAX(commit_hash, commit_ts) AS last_dev_commit_hash,
    MAX(commit_ts) AS last_dev_commit_ts
  FROM dev_commits
  GROUP BY ALL
),

ga_majors AS (
  SELECT DISTINCT major
  FROM {{ ref('stg_git_tags') }}
  WHERE tag_kind = 'release' AND minor = 0
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
  pmj.dev_commit_cnt,
  pmj.first_dev_commit_hash,
  pmj.first_dev_commit_ts,
  {{ utc_date('pmj.first_dev_commit_ts') }} AS first_dev_commit_dt,
  pmj.last_dev_commit_hash,
  pmj.last_dev_commit_ts,
  {{ utc_date('pmj.last_dev_commit_ts') }} AS last_dev_commit_dt
FROM per_major AS pmj
LEFT JOIN ga_majors AS gam ON pmj.major = gam.major
LEFT JOIN latest_prerelease AS lpr ON pmj.major = lpr.major
