SELECT
  version,
  major::INTEGER AS major,
  minor::INTEGER AS minor,
  "date"::DATE AS release_date,
  n_items::INTEGER AS n_items
FROM {{ source('scraped', 'releases') }}
