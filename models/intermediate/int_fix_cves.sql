-- One row per (distinct fix, CVE): the fix's ';'-joined cves list exploded
-- once here, instead of in dim_cve, bridge_fix_cve, fct_fixes and dim_release
-- separately. Carries release_dt so the release rollup can count
-- distinct CVEs without re-exploding. Grain = (item_ord, cve_id).
SELECT DISTINCT
  reps.item_ord,
  reps.release_dt,
  TRIM(cve.cve_id) AS cve_id
FROM {{ ref('int_fix_reps') }} AS reps,
  UNNEST(STRING_SPLIT(reps.cves, ';')) AS cve (cve_id)
WHERE reps.cves IS NOT null AND TRIM(cve.cve_id) != ''
