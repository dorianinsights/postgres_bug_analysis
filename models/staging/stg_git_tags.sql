WITH parsed AS (
  SELECT
    tag,
    tag_ts,
    REGEXP_EXTRACT(tag, '^REL_(\d+)_(\d+|(?:BETA|RC)\d+)$', 1)::INTEGER AS major,
    REGEXP_EXTRACT(tag, '^REL_(\d+)_(\d+|(?:BETA|RC)\d+)$', 2) AS suffix
  FROM {{ ref('raw_git_tags') }}
  WHERE REGEXP_FULL_MATCH(tag, 'REL_\d+_(\d+|(BETA|RC)\d+)')
),

typed AS (
  SELECT
    tag,
    tag_ts,
    major,
    -- a numeric suffix is a minor release; BETAn / RCn is a prerelease milestone
    TRY_CAST(suffix AS INTEGER) AS minor,
    CASE WHEN TRY_CAST(suffix AS INTEGER) IS null THEN suffix END AS milestone
  FROM parsed
)

SELECT
  tag,
  CASE WHEN minor IS NOT null THEN 'release' ELSE 'prerelease' END AS tag_kind,
  major,
  minor,
  milestone,
  tag_ts::TIMESTAMPTZ AS tag_ts,
  {{ utc_date('tag_ts::TIMESTAMPTZ') }} AS tag_dt
FROM typed
