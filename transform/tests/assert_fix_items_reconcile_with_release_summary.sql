-- The fix-grain fact and the release rollup must agree: fct_fixes rows per
-- release = release_summary.distinct_fix_cnt.
WITH per_release AS (
  SELECT
    release_dt,
    COUNT(*) AS fix_cnt
  FROM {{ ref('fct_fixes') }}
  GROUP BY release_dt
)

SELECT
  wsm.release_dt,
  wsm.distinct_fix_cnt,
  COALESCE(pwv.fix_cnt, 0) AS fix_cnt
FROM {{ ref('dim_release') }} AS wsm
LEFT JOIN per_release AS pwv ON wsm.release_dt = pwv.release_dt
WHERE wsm.status = 'shipped' AND wsm.distinct_fix_cnt != COALESCE(pwv.fix_cnt, 0)
