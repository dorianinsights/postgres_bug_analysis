-- Wave-grain rollup of the deduped fixes. The wave_summary mart is a pure
-- ordered SELECT of this table; projections and git_cycle_pace also read it
-- (rather than the external mart, to avoid re-sniffing the written CSV).
WITH fix_counts AS (
  SELECT
    wave_dt,
    COUNT(*) AS distinct_fixes,
    COUNT(*) FILTER (
      WHERE category IN ('Security (CVE)', 'Security hardening (no CVE)')
    ) AS security_fixes
  FROM {{ ref('int_fix_reps') }}
  GROUP BY wave_dt
),

cve_counts AS (
  SELECT
    wave_dt,
    COUNT(DISTINCT cve) AS distinct_cves
  FROM (
    SELECT
      wave_dt,
      UNNEST(STRING_SPLIT(cves, ';')) AS cve
    FROM {{ ref('int_fix_reps') }}
    WHERE cves IS NOT null
  )
  WHERE cve != ''
  GROUP BY wave_dt
)

SELECT
  waves.wave_dt,
  waves.versions,
  waves.n_releases,
  COALESCE(fix.distinct_fixes, 0) AS distinct_fixes,
  COALESCE(cve.distinct_cves, 0) AS distinct_cves,
  COALESCE(fix.security_fixes, 0) AS security_fixes,
  waves.out_of_band::INTEGER AS out_of_band,
  waves.partial_window::INTEGER AS partial_window
FROM {{ ref('int_waves') }} AS waves
LEFT JOIN fix_counts AS fix ON waves.wave_dt = fix.wave_dt
LEFT JOIN cve_counts AS cve ON waves.wave_dt = cve.wave_dt
