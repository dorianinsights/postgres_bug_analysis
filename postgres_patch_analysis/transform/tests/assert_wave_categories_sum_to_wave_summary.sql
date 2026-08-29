-- Category counts partition the deduped fixes: their per-wave sum must
-- equal wave_summary.distinct_fixes.
WITH per_wave AS (
  SELECT
    wave_date,
    SUM(fixes) AS n_fixes
  FROM {{ ref('wave_categories') }}
  GROUP BY wave_date
)

SELECT
  wsm.wave_date,
  wsm.distinct_fixes,
  COALESCE(pwv.n_fixes, 0) AS n_fixes
FROM {{ ref('wave_summary') }} AS wsm
LEFT JOIN per_wave AS pwv ON wsm.wave_date = pwv.wave_date
WHERE wsm.distinct_fixes != COALESCE(pwv.n_fixes, 0)
