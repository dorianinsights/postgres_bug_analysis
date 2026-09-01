-- The raw file carries every REL_1x_* ref verbatim, prereleases included.
-- Staging keeps only release tags (REL_MAJOR_MINOR — BETA/RC refs like
-- REL_18_BETA1 are filtered out) and derives major/minor from the name.
-- tag_ts: full creation timestamp. tag_dt is that instant's UTC calendar day,
-- derived once here (pinned to UTC so the day boundary can't drift with the
-- session timezone) so consumers use a plain column instead of re-truncating;
-- the full-precision tag_ts instant is kept alongside.
-- NULLIF before the cast: the projection can be evaluated before the WHERE
-- filter, so a prerelease row's non-matching extract ('') must become NULL
-- rather than a failed INTEGER cast. Release rows always match, and the
-- not_null tests still catch any release-shaped tag that doesn't.
SELECT
  tag,
  NULLIF(REGEXP_EXTRACT(tag, '^REL_(\d+)_(\d+)$', 1), '')::INTEGER AS major,
  NULLIF(REGEXP_EXTRACT(tag, '^REL_(\d+)_(\d+)$', 2), '')::INTEGER AS minor,
  tag_ts::TIMESTAMPTZ AS tag_ts,
  (tag_ts::TIMESTAMPTZ AT TIME ZONE 'utc')::DATE AS tag_dt
FROM {{ ref('raw_git_tags') }}
WHERE REGEXP_FULL_MATCH(tag, 'REL_\d+_\d+')
