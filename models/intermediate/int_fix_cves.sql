SELECT
  reps.item_ord,
  reps.release_dt,
  cve.cve_id
FROM {{ ref('int_fix_reps') }} AS reps,
  UNNEST(reps.cves) AS cve (cve_id)
