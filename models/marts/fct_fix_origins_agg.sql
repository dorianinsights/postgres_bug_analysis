SELECT
  rof.release_dt,
  rel.dim_release_key,
  rof.status,
  rel.is_out_of_band,
  rel.is_partial_window,
  rof.origin,
  rof.fix_cnt,
  rof.security_fix_cnt,
  rof.committed_fix_cnt,
  (rof.fix_cnt::DECIMAL(15, 6) / NULLIF(rof.committed_fix_cnt, 0))::DECIMAL(7, 6) AS documentation_rate,
  (rof.fix_cnt::DECIMAL(18, 6) / NULLIF(SUM(rof.fix_cnt) OVER (PARTITION BY rof.release_dt), 0))::DECIMAL(7, 6) AS fix_share
FROM {{ ref('int_release_origin_fixes') }} AS rof
INNER JOIN {{ ref('int_releases') }} AS rel ON rof.release_dt = rel.release_dt
