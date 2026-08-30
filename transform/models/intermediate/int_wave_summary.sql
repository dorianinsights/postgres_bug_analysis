-- Wave-grain rollup of the deduped fixes. The wave_summary mart is a pure
-- ordered SELECT of this table; projections and git_cycle_pace also read it
-- (rather than the external mart, to avoid re-sniffing the written CSV).
WITH fix_counts AS (
  SELECT
    wave_dt,
    COUNT(*) AS distinct_fix_cnt,
    COUNT(*) FILTER (
      WHERE category IN ('Security (CVE)', 'Security hardening (no CVE)')
    ) AS security_fix_cnt
  FROM {{ ref('int_fix_reps') }}
  GROUP BY ALL
),

cve_counts AS (
  SELECT
    wave_dt,
    COUNT(DISTINCT cve_id) AS distinct_cve_cnt
  FROM {{ ref('int_fix_cves') }}
  GROUP BY ALL
)

SELECT
  waves.wave_dt,
  waves.versions,
  waves.release_cnt,
  COALESCE(fix.distinct_fix_cnt, 0) AS distinct_fix_cnt,
  COALESCE(cve.distinct_cve_cnt, 0) AS distinct_cve_cnt,
  COALESCE(fix.security_fix_cnt, 0) AS security_fix_cnt,
  waves.is_out_of_band,
  waves.is_partial_window
FROM {{ ref('int_waves') }} AS waves
LEFT JOIN fix_counts AS fix ON waves.wave_dt = fix.wave_dt
LEFT JOIN cve_counts AS cve ON waves.wave_dt = cve.wave_dt
