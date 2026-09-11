-- fct_fix_projections forecasts only the full-quarter scheduled releases with
-- cycle signals: a row keyed to an out-of-band re-release, the corpus's
-- partial-window first release, a future release, or a special member would
-- be a target the methods were never defined for (and, once shipped, one
-- whose actual is not comparable).
SELECT
  prj.dim_release_key,
  prj.projection_method
FROM {{ ref('fct_fix_projections') }} AS prj
INNER JOIN {{ ref('dim_release') }} AS rel ON prj.dim_release_key = rel.dim_release_key
WHERE
  rel.is_synthetic_row
  OR rel.is_out_of_band
  OR rel.is_partial_window
  OR rel.status NOT IN ('shipped', 'open')
  OR rel.cycle_start_dt IS null
