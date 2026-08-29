-- tag_ts: the full tag-creation timestamp (ISO 8601 with offset), cast
-- strictly to TIMESTAMP WITH TIME ZONE. Day-truncation happens downstream
-- at the point of use.
SELECT
  tag,
  major::INTEGER AS major,
  minor::INTEGER AS minor,
  tag_ts::TIMESTAMPTZ AS tag_ts
FROM {{ source('scraped', 'git_tags') }}
