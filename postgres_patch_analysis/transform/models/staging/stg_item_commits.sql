-- commit_ts: the annotation's committer timestamp ("YYYY-MM-DD HH:MM:SS
-- +ZZZZ", occasionally followed by an author aside such as "!! no live
-- bug"). The fixed-width 25-char prefix is parsed; the aside is dropped.
-- STRPTIME with %z yields TIMESTAMP WITH TIME ZONE and raises on any
-- malformed row rather than passing NULL through silently.
-- The raw author is "Name <email>" (all rows match; 31 distinct authors).
-- NULLIF turns a non-matching extract into NULL so a shape break fails the
-- not_null tests instead of passing '' through.
SELECT
  version,
  item_index::INTEGER AS item_index,
  NULLIF(TRIM(REGEXP_EXTRACT(author, '^([^<>]+)<', 1)), '') AS author_name,
  NULLIF(REGEXP_EXTRACT(author, '<([^<>]+)>', 1), '') AS author_email,
  branch,
  commit_hash,
  STRPTIME(commit_date[1:25], '%Y-%m-%d %H:%M:%S %z') AS commit_ts
FROM {{ source('scraped', 'item_commits') }}
