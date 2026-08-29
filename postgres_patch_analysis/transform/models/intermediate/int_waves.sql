-- One same-day release wave. ".0" feature releases are not fixes and are
-- excluded before grouping. A wave is out-of-band (emergency re-release)
-- when its LARGEST release has fewer than 20 items; the corpus's first wave
-- is a partial accumulation window (15.1 shipped ~4 weeks after 15.0).
WITH fix_releases AS (
  SELECT *
  FROM {{ ref('stg_releases') }}
  WHERE minor > 0
),

grouped AS (
  SELECT
    release_dt AS wave_dt,
    STRING_AGG(version, ' / ' ORDER BY major, minor) AS versions,
    COUNT(*) AS n_releases,
    MAX(n_items) < 20 AS out_of_band
  FROM fix_releases
  GROUP BY release_dt
)

SELECT
  *,
  wave_dt = MIN(wave_dt) OVER () AS partial_window
FROM grouped
