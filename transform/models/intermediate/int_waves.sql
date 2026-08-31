-- One same-day release wave. ".0" feature releases are not fixes and are
-- excluded before grouping. A wave is out-of-band (emergency re-release)
-- when its LARGEST release has fewer than var(scheduled_wave_min_items)
-- items — counted here from
-- stg_release_items (the scraper's n_items column stays in raw only as a
-- scrape-consistency checksum; see assert_release_items_match_n_items).
-- The corpus's first wave is a partial accumulation window (15.1 shipped
-- ~4 weeks after 15.0).
WITH item_counts AS (
  SELECT
    version,
    COUNT(*) AS parsed_item_cnt
  FROM {{ ref('stg_release_items') }}
  GROUP BY ALL
),

fix_releases AS (
  SELECT
    rel.version,
    rel.major,
    rel.minor,
    rel.release_dt,
    cnt.parsed_item_cnt
  FROM {{ ref('int_releases') }} AS rel
  INNER JOIN item_counts AS cnt ON rel.version = cnt.version
  WHERE rel.minor > 0
),

grouped AS (
  SELECT
    release_dt AS wave_dt,
    STRING_AGG(version, ' / ' ORDER BY major, minor) AS versions,
    COUNT(*) AS release_cnt,
    MAX(parsed_item_cnt) < {{ var('scheduled_wave_min_items') }} AS is_out_of_band
  FROM fix_releases
  GROUP BY ALL
)

SELECT
  *,
  wave_dt = MIN(wave_dt) OVER () AS is_partial_window
FROM grouped
