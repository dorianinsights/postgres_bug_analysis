SELECT
  version,
  item_index::INTEGER AS item_index,
  -- a non-matching "Name <email>" becomes NULL so the not_null tests catch a shape break
  NULLIF(TRIM(REGEXP_EXTRACT(author, '^([^<>]+)<', 1)), '') AS author_name,
  NULLIF(REGEXP_EXTRACT(author, '<([^<>]+)>', 1), '') AS author_email,
  branch,
  commit_hash,
  -- the fixed-width 25-char timestamp; an author aside ("!! no live bug") sometimes follows
  STRPTIME(commit_date[1:25], '%Y-%m-%d %H:%M:%S %z') AS commit_ts
FROM {{ ref('raw_item_commits') }}
