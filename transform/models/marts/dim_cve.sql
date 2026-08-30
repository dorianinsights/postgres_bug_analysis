-- CVE dimension: one row per CVE referenced by a corpus fix, with its CVSS v3
-- severity where PostgreSQL publishes it. Scoped to the CVEs the fixes actually
-- cite (from int_fix_reps.cves) rather than every published CVE, so it conforms
-- exactly to what the facts/bridges reference. The two long-EOL CVEs the
-- security page no longer lists stay here with NULL severity. Grain = cve_id.
-- -> ../data/derived/dim_cve.csv
WITH corpus_cves AS (
  SELECT DISTINCT TRIM(cve.cve_id) AS cve_id
  FROM {{ ref('int_fix_reps') }} AS reps,
    UNNEST(STRING_SPLIT(reps.cves, ';')) AS cve (cve_id)
  WHERE reps.cves IS NOT null
)

SELECT
  cvs.cve_id,
  sev.cvss_base_score,
  sev.severity_band,
  sev.cvss_vector,
  sev.component,
  sev.cve_id IS null AS is_severity_unlisted
FROM corpus_cves AS cvs
LEFT JOIN {{ ref('stg_cve_severity') }} AS sev ON cvs.cve_id = sev.cve_id
