-- commit_date stays VARCHAR: it is the raw "YYYY-MM-DD HH:MM:SS +ZZZZ" text
-- of the SGML Branch annotation, carried through but never computed on.
SELECT
  version,
  item_index::INTEGER AS item_index,
  author,
  branch,
  commit_hash,
  commit_date
FROM {{ source('scraped', 'item_commits') }}
