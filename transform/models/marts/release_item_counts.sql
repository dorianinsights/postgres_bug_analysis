-- One row per minor/major release with its changelog item count, serving the
-- changelog dashboard's per-release trend charts (which previously read the
-- retired raw releases.csv directly). It reunites the two halves of the release
-- picture: release_dt is the git-tag-derived announced date (int_releases), and
-- item_cnt is the parsed changelog item count from the SGML notes -- exactly the
-- (date, n_items) releases.csv used to carry. Grain = version.
-- -> ../data/derived/release_item_counts.csv
WITH item_counts AS (
  SELECT
    version,
    COUNT(*)::BIGINT AS item_cnt
  FROM {{ ref('stg_release_items') }}
  GROUP BY version
)

SELECT
  rel.version,
  rel.major,
  rel.minor,
  rel.release_dt,
  cnt.item_cnt
FROM {{ ref('int_releases') }} AS rel
INNER JOIN item_counts AS cnt ON rel.version = cnt.version
