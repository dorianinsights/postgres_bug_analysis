-- Tidy (release-wave, category) distinct-fix counts, aggregated straight from
-- the fix-grain star (a fix has exactly one category, so no bridge needed).
-- Conforms to dim_release via dim_release_key. Only categories present in a wave
-- appear, so fix_cnt >= 1. Grain = (dim_release_key, category).
SELECT
  fix.dim_release_key,
  fix.wave_dt AS release_dt,
  fix.category,
  fix.category_order,
  fix.is_out_of_band,
  COUNT(*) AS fix_cnt
FROM {{ ref('fct_fixes') }} AS fix
GROUP BY ALL
