-- Fix<->CVE bridge: one row per (fix, CVE) since a single fix can remediate
-- several CVEs. Resolves the many-to-many between fct_fixes and dim_cve so
-- per-CVE rollups stay correct (fct_fixes keeps only the worst severity).
-- Grain = (item_ord, cve_id). -> ../data/derived/bridge_fix_cve.csv
SELECT DISTINCT
  reps.item_ord,
  TRIM(cve.cve_id) AS cve_id
FROM {{ ref('int_fix_reps') }} AS reps,
  UNNEST(STRING_SPLIT(reps.cves, ';')) AS cve (cve_id)
WHERE reps.cves IS NOT null
