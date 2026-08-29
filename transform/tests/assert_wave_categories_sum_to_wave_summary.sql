-- Category counts partition the deduped fixes: their per-wave sum must
-- equal wave_summary.distinct_fixes.
WITH per_wave AS (
  SELECT
    wave_dt,
    SUM(fixes) AS n_fixes
  FROM {{ ref('wave_categories') }}
  GROUP BY wave_dt
)

SELECT
  wsm.wave_dt,
  wsm.distinct_fixes,
  COALESCE(pwv.n_fixes, 0) AS n_fixes
FROM {{ ref('wave_summary') }} AS wsm
LEFT JOIN per_wave AS pwv ON wsm.wave_dt = pwv.wave_dt
WHERE wsm.distinct_fixes != COALESCE(pwv.n_fixes, 0)
