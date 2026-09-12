WITH first_release AS (
  SELECT MIN(release_dt) AS release_dt
  FROM {{ ref('dim_release') }}
  WHERE status = 'shipped'
)

SELECT
  fix.dim_release_key,
  fix.release_dt,
  bfc.contributor,
  COUNT(*) AS credit_cnt,
  MIN(fix.release_dt) OVER (PARTITION BY bfc.contributor) AS first_seen_release_dt,
  -- a debut, except in the corpus's first release where everyone is trivially new
  (
    first_seen_release_dt = fix.release_dt
    AND fix.release_dt != (SELECT fwv.release_dt FROM first_release AS fwv)
  ) AS is_first_release,
  fix.is_out_of_band
FROM {{ ref('fct_fixes') }} AS fix
INNER JOIN {{ ref('bridge_fix_contributor') }} AS bfc ON fix.item_ord = bfc.item_ord
GROUP BY fix.dim_release_key, fix.release_dt, bfc.contributor, fix.is_out_of_band
