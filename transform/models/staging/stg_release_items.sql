-- "full" is a reserved word (FULL JOIN); renamed full_text here. CVE ids
-- are no longer a raw column — int_fix_items derives them from full_text.
SELECT
  version,
  major::INTEGER AS major,
  date::DATE AS release_dt,
  item_index::INTEGER AS item_index,
  summary,
  "full" AS full_text
FROM {{ ref('raw_release_items') }}
