SELECT
  dim_release_key,
  release_dt,
  category,
  category_order,
  is_out_of_band,
  COUNT(*) AS fix_cnt,
  (fix_cnt::DECIMAL(18, 6) / NULLIF(SUM(fix_cnt) OVER (PARTITION BY release_dt), 0))::DECIMAL(7, 6) AS fix_share
FROM {{ ref('fct_fixes') }}
GROUP BY dim_release_key, release_dt, category, category_order, is_out_of_band
