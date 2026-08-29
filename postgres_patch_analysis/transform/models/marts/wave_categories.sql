{{ config(materialized='external', location='../data/derived/wave_categories.csv', format='csv') }}

-- Tidy (wave, category) fix counts; only categories present in the wave.
SELECT
  reps.wave_date,
  reps.category,
  cats.category_order,
  COUNT(*) AS fixes,
  waves.out_of_band::INTEGER AS out_of_band
FROM {{ ref('int_fix_reps') }} AS reps
INNER JOIN {{ ref('categories') }} AS cats USING (category)
INNER JOIN {{ ref('int_waves') }} AS waves USING (wave_date)
GROUP BY reps.wave_date, reps.category, cats.category_order, waves.out_of_band
ORDER BY reps.wave_date, cats.category_order
