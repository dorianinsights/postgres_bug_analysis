SELECT
  version,
  major::INTEGER AS major,
  date::DATE AS release_dt,
  item_index::INTEGER AS item_index,
  summary,
  -- "full" is a reserved word (FULL JOIN)
  "full" AS full_text
FROM {{ ref('raw_release_items') }}
