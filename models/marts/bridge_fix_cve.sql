SELECT
  fcv.item_ord,
  dcv.dim_cve_key
FROM {{ ref('int_fix_cves') }} AS fcv
INNER JOIN {{ ref('dim_cve') }} AS dcv ON fcv.cve_id = dcv.cve_id
