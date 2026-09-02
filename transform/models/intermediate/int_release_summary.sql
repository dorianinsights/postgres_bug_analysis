-- Shipped-release rollup of the deduped fixes: one row per shipped release with
-- its fix/CVE/security counts. Feeds dim_release's measures, and projections +
-- int_release_cycles read it (rather than the CSV twin, to avoid re-sniffing).
-- Restricted to shipped releases (the upcoming ones in int_releases have no
-- fixes yet). One row per shipped release.
WITH fix_counts AS (
  SELECT
    release_dt,
    COUNT(*) AS distinct_fix_cnt,
    -- CVE-bearing fixes; security is CVE-anchored now that it is a flag rather
    -- than a category (is_security_hardening is tracked separately on fct_fixes)
    COUNT(*) FILTER (WHERE cves IS NOT null) AS security_fix_cnt
  FROM {{ ref('int_fix_reps') }}
  GROUP BY ALL
),

cve_counts AS (
  SELECT
    release_dt,
    COUNT(DISTINCT cve_id) AS distinct_cve_cnt
  FROM {{ ref('int_fix_cves') }}
  GROUP BY ALL
)

SELECT
  rel.release_dt,
  rel.versions,
  rel.release_cnt,
  COALESCE(fix.distinct_fix_cnt, 0) AS distinct_fix_cnt,
  COALESCE(cve.distinct_cve_cnt, 0) AS distinct_cve_cnt,
  COALESCE(fix.security_fix_cnt, 0) AS security_fix_cnt,
  rel.is_out_of_band,
  rel.is_partial_window
FROM {{ ref('int_releases') }} AS rel
LEFT JOIN fix_counts AS fix ON rel.release_dt = fix.release_dt
LEFT JOIN cve_counts AS cve ON rel.release_dt = cve.release_dt
WHERE rel.status = 'shipped'
