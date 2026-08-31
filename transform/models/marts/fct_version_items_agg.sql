-- Changelog item count per individual release (version grain) -- an aggregate
-- fact conforming to dim_version on dim_version_key. Formerly release_item_counts,
-- which carried the release's date/major/minor inline; those attributes now
-- live in dim_version, leaving this a clean FK + measure. item_cnt is the
-- parsed changelog-item count from the SGML notes.
-- Grain = dim_version_key. -> ../data/derived/fct_version_items_agg.csv
WITH item_counts AS (
  SELECT
    version,
    COUNT(*)::BIGINT AS item_cnt
  FROM {{ ref('stg_release_items') }}
  GROUP BY version
)

SELECT
  {{ dbt_utils.generate_surrogate_key(['rel.version']) }} AS dim_version_key,
  cnt.item_cnt
FROM {{ ref('int_releases') }} AS rel
INNER JOIN item_counts AS cnt ON rel.version = cnt.version
