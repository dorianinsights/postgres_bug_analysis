-- The BETA / RC milestone tags (REL_M_BETA1, REL_M_RC1, ...) that stg_git_tags
-- filters OUT: one row per prerelease ref, with the major and the milestone
-- name parsed from the tag. int_major_development reads the newest one to
-- label the in-progress major's stage. Same NULLIF-before-cast pattern as
-- stg_git_tags (the projection can run before the WHERE filter).
-- Grain = tag.
SELECT
  tag,
  NULLIF(REGEXP_EXTRACT(tag, '^REL_(\d+)_((?:BETA|RC)\d+)$', 1), '')::INTEGER AS major,
  NULLIF(REGEXP_EXTRACT(tag, '^REL_(\d+)_((?:BETA|RC)\d+)$', 2), '') AS milestone,
  tag_ts::TIMESTAMPTZ AS tag_ts,
  (tag_ts::TIMESTAMPTZ AT TIME ZONE 'utc')::DATE AS tag_dt
FROM {{ ref('raw_git_tags') }}
WHERE REGEXP_FULL_MATCH(tag, 'REL_\d+_(BETA|RC)\d+')
