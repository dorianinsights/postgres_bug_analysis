-- One published PostgreSQL CVE with its CVSS v3 base score and vector,
-- typed from the raw scrape. The base score sniffs to VARCHAR upstream
-- (the source's auto_type_candidates omit DOUBLE so version strings can't
-- collapse), so cast it to DOUBLE here. severity_band is DERIVED from the
-- score using the standard CVSS v3 ranges (0 NONE; <4 LOW; <7 MEDIUM;
-- <9 HIGH; else CRITICAL) — the band is analysis, so it lives in the
-- transform, not the scraper. Empty scores (a listed CVE with no CVSS)
-- become NULL and fall outside every band.
SELECT
  cve_id,
  NULLIF(component, '') AS component,
  NULLIF(cvss_base_score, '')::DOUBLE AS cvss_base_score,
  NULLIF(cvss_vector, '') AS cvss_vector,
  CASE
    WHEN NULLIF(cvss_base_score, '') IS null THEN null
    WHEN cvss_base_score::DOUBLE = 0 THEN 'NONE'
    WHEN cvss_base_score::DOUBLE < 4 THEN 'LOW'
    WHEN cvss_base_score::DOUBLE < 7 THEN 'MEDIUM'
    WHEN cvss_base_score::DOUBLE < 9 THEN 'HIGH'
    ELSE 'CRITICAL'
  END AS severity_band
FROM {{ source('scraped', 'cve_severity') }}
