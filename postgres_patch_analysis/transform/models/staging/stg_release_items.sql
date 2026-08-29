-- "full" is a reserved word (FULL JOIN); renamed full_text here. The empty
-- cves string round-trips to NULL through the CSV reader; coalesce restores
-- the '' convention ("no CVEs") the loaders established.
SELECT
  version,
  major::INTEGER AS major,
  date::DATE AS release_date,
  item_index::INTEGER AS item_index,
  summary,
  "full" AS full_text,
  COALESCE(cves, '') AS cves
FROM {{ source('scraped', 'release_items') }}
