-- Category counts partition the deduped fixes: their per-release sum must
-- equal release_summary.distinct_fix_cnt.
WITH per_release AS (
  SELECT
    dim_release_key,
    SUM(fix_cnt) AS fix_cnt
  FROM {{ ref('fct_release_categories_agg') }}
  GROUP BY dim_release_key
)

SELECT
  wsm.release_dt,
  wsm.distinct_fix_cnt,
  COALESCE(pwv.fix_cnt, 0) AS fix_cnt
FROM {{ ref('dim_release') }} AS wsm
LEFT JOIN per_release AS pwv ON wsm.dim_release_key = pwv.dim_release_key
WHERE wsm.status = 'shipped' AND wsm.distinct_fix_cnt != COALESCE(pwv.fix_cnt, 0)
