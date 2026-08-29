-- "full" is a reserved word (FULL JOIN); renamed full_text here. cves is
-- NULL when the item carries no CVEs (the raw CSV's empty string reads as
-- NULL, and staging keeps it that way — no empty strings in this layer).
SELECT
  version,
  major::INTEGER AS major,
  date::DATE AS release_dt,
  item_index::INTEGER AS item_index,
  summary,
  "full" AS full_text,
  cves
FROM {{ source('scraped', 'release_items') }}
