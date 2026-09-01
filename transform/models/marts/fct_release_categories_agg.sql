-- Tidy (release-release, category) distinct-fix counts, aggregated straight from
-- the fix-grain star (a fix has exactly one category, so no bridge needed).
-- Conforms to dim_release via dim_release_key. Only categories present in a release
-- appear, so fix_cnt >= 1. fix_share is the category's share of its release's
-- fixes (a ratio, so DECIMAL not float), computed here instead of as an inline
-- window in the changelog chart. Grain = (dim_release_key, category).
WITH agg AS (
  SELECT
    fix.dim_release_key,
    fix.release_dt,
    fix.category,
    fix.category_order,
    fix.is_out_of_band,
    COUNT(*) AS fix_cnt
  FROM {{ ref('fct_fixes') }} AS fix
  GROUP BY ALL
)

SELECT
  dim_release_key,
  release_dt,
  category,
  category_order,
  is_out_of_band,
  fix_cnt,
  (fix_cnt::DECIMAL(18, 6) / NULLIF(SUM(fix_cnt) OVER (PARTITION BY release_dt), 0))::DECIMAL(7, 6) AS fix_share
FROM agg
