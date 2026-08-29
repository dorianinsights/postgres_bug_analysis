-- Every release's row count in release_items must equal releases.n_items —
-- catches the two raw files coming from different scraper runs.
WITH item_counts AS (
  SELECT
    version,
    COUNT(*) AS n_rows
  FROM {{ ref('stg_release_items') }}
  GROUP BY version
)

SELECT
  rel.version,
  rel.n_items,
  COALESCE(cnt.n_rows, 0) AS n_rows
FROM {{ ref('stg_releases') }} AS rel
LEFT JOIN item_counts AS cnt ON rel.version = cnt.version
WHERE rel.n_items != COALESCE(cnt.n_rows, 0)
