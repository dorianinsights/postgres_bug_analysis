SELECT DISTINCT
  reps.item_ord,
  reps.release_dt,
  TRIM(cve.cve_id) AS cve_id
FROM {{ ref('int_fix_reps') }} AS reps,
  UNNEST(STRING_SPLIT(reps.cves, ';')) AS cve (cve_id)
WHERE reps.cves IS NOT null AND TRIM(cve.cve_id) != ''
