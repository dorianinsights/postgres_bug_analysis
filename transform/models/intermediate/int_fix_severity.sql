-- CVE severity for each distinct fix that carries one or more CVE ids.
-- int_fix_reps.cves is a ';'-joined list (a fix can remediate several
-- CVEs); this unnests it, joins the per-CVE CVSS data, and keeps the WORST
-- (highest base score) as the fix's severity. The band is NOT recomputed here:
-- stg_cve_severity already banded each CVE from the cvss_severity_bands seed,
-- so arg_max pulls the worst CVE's band + order straight from there (the band
-- is monotonic in the score, so the max-score CVE carries the worst band). The
-- seed therefore lives in exactly one model. scored_cve_cnt < cve_cnt records
-- CVEs the security page doesn't list (long-EOL majors -- e.g. the 2012/2017
-- ids -- legitimately have no CVSS row). Grain = item_ord (one row per
-- CVE-bearing fix).
WITH joined AS (
  SELECT
    fcv.item_ord,
    fcv.cve_id,
    sev.cvss_base_score,
    sev.severity_band,
    sev.severity_band_order
  FROM {{ ref('int_fix_cves') }} AS fcv
  LEFT JOIN {{ ref('stg_cve_severity') }} AS sev ON fcv.cve_id = sev.cve_id
)

SELECT
  item_ord,
  COUNT(*)::BIGINT AS cve_cnt,
  COUNT(cvss_base_score)::BIGINT AS scored_cve_cnt,
  MAX(cvss_base_score) AS max_cvss_base_score,
  ARG_MAX(severity_band, cvss_base_score) AS severity_band,
  ARG_MAX(severity_band_order, cvss_base_score) AS severity_band_order
FROM joined
GROUP BY ALL
