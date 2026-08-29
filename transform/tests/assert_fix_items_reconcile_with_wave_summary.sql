-- The item-grain fact and the wave rollup must agree: fix_items rows per
-- wave = wave_summary.distinct_fixes.
WITH per_wave AS (
  SELECT
    wave_dt,
    COUNT(*) AS n_fixes
  FROM {{ ref('fix_items') }}
  GROUP BY wave_dt
)

SELECT
  wsm.wave_dt,
  wsm.distinct_fixes,
  COALESCE(pwv.n_fixes, 0) AS n_fixes
FROM {{ ref('wave_summary') }} AS wsm
LEFT JOIN per_wave AS pwv ON wsm.wave_dt = pwv.wave_dt
WHERE wsm.distinct_fixes != COALESCE(pwv.n_fixes, 0)
