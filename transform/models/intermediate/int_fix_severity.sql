-- CVE severity for each distinct fix that carries one or more CVE ids.
-- int_fix_reps.cves is a ';'-joined list (a fix can remediate several
-- CVEs); this unnests it, joins the scraped CVSS data, and keeps the
-- WORST (highest base score) as the fix's severity. scored_cve_cnt <
-- cve_cnt records CVEs the security page doesn't list (long-EOL majors —
-- e.g. the 2012/2017 ids — legitimately have no CVSS row). Grain =
-- item_ord (one row per CVE-bearing fix).
WITH exploded AS (
  SELECT
    reps.item_ord,
    TRIM(cve.cve_id) AS cve_id
  FROM {{ ref('int_fix_reps') }} AS reps,
    UNNEST(STRING_SPLIT(reps.cves, ';')) AS cve (cve_id)
  WHERE reps.cves IS NOT null
),

joined AS (
  SELECT
    exp.item_ord,
    exp.cve_id,
    sev.cvss_base_score
  FROM exploded AS exp
  LEFT JOIN {{ ref('stg_cve_severity') }} AS sev ON exp.cve_id = sev.cve_id
)

SELECT
  item_ord,
  COUNT(*)::BIGINT AS cve_cnt,
  COUNT(cvss_base_score)::BIGINT AS scored_cve_cnt,
  MAX(cvss_base_score) AS max_cvss_base_score,
  CASE
    WHEN MAX(cvss_base_score) IS null THEN null
    WHEN MAX(cvss_base_score) = 0 THEN 'NONE'
    WHEN MAX(cvss_base_score) < 4 THEN 'LOW'
    WHEN MAX(cvss_base_score) < 7 THEN 'MEDIUM'
    WHEN MAX(cvss_base_score) < 9 THEN 'HIGH'
    ELSE 'CRITICAL'
  END AS severity_band
FROM joined
GROUP BY ALL
