-- Fix<->CVE bridge: one row per (fix, CVE) since a single fix can remediate
-- several CVEs. Resolves the many-to-many between fct_fixes and dim_cve so
-- per-CVE rollups stay correct (fct_fixes keeps only the worst severity).
-- Grain = (item_ord, dim_cve_key).
SELECT
  fcv.item_ord,
  dcv.dim_cve_key
FROM {{ ref('int_fix_cves') }} AS fcv
INNER JOIN {{ ref('dim_cve') }} AS dcv ON fcv.cve_id = dcv.cve_id
