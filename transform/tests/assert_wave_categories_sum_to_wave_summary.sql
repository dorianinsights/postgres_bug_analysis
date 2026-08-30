-- Category counts partition the deduped fixes: their per-wave sum must
-- equal wave_summary.distinct_fix_cnt.
WITH per_wave AS (
  SELECT
    wave_dt,
    SUM(fix_cnt) AS fix_cnt
  FROM {{ ref('wave_categories') }}
  GROUP BY wave_dt
)

SELECT
  wsm.release_dt,
  wsm.distinct_fix_cnt,
  COALESCE(pwv.fix_cnt, 0) AS fix_cnt
FROM {{ ref('dim_release') }} AS wsm
LEFT JOIN per_wave AS pwv ON wsm.release_dt = pwv.wave_dt
WHERE wsm.status = 'shipped' AND wsm.distinct_fix_cnt != COALESCE(pwv.fix_cnt, 0)
