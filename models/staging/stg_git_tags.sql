SELECT
  tag,
  REGEXP_EXTRACT(tag, '^REL_(\d+)_(\d+|(?:BETA|RC)\d+)$', 1)::INTEGER AS major,
  -- a numeric suffix is a minor release; BETAn / RCn is a prerelease milestone
  TRY_CAST(REGEXP_EXTRACT(tag, '^REL_(\d+)_(\d+|(?:BETA|RC)\d+)$', 2) AS INTEGER) AS minor,
  CASE WHEN minor IS null THEN REGEXP_EXTRACT(tag, '^REL_(\d+)_(\d+|(?:BETA|RC)\d+)$', 2) END AS milestone,
  CASE WHEN minor IS NOT null THEN 'release' ELSE 'prerelease' END AS tag_kind,
  -- the .0 that opens a major line; false for its minors and prereleases
  COALESCE(minor = 0, false) AS is_major_release,
  -- the release's version string (17.6); NULL for a prerelease
  CASE WHEN minor IS NOT null THEN major::VARCHAR || '.' || minor::VARCHAR END AS version,
  -- the git branch every tag of the major lives on
  'REL_' || major || '_STABLE' AS stable_branch,
  tag_ts::TIMESTAMPTZ AS tag_ts,
  {{ utc_date('tag_ts::TIMESTAMPTZ') }} AS tag_dt
FROM {{ ref('raw_git_tags') }}
WHERE REGEXP_FULL_MATCH(tag, 'REL_\d+_(\d+|(BETA|RC)\d+)')
