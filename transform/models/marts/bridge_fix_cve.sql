-- Fix<->CVE bridge: one row per (fix, CVE) since a single fix can remediate
-- several CVEs. Resolves the many-to-many between fct_fixes and dim_cve so
-- per-CVE rollups stay correct (fct_fixes keeps only the worst severity).
-- Grain = (item_ord, cve_id).
SELECT
  item_ord,
  cve_id
FROM {{ ref('int_fix_cves') }}
