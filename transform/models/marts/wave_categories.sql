-- Tidy (wave, category) fix counts; only categories present in the wave.
SELECT
  reps.wave_dt,
  reps.category,
  cats.category_order,
  waves.is_out_of_band,
  COUNT(*) AS fix_cnt
FROM {{ ref('int_fix_reps') }} AS reps
INNER JOIN {{ ref('categories') }} AS cats ON reps.category = cats.category
INNER JOIN {{ ref('int_waves') }} AS waves ON reps.wave_dt = waves.wave_dt
GROUP BY ALL
