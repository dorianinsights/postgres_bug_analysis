-- One published PostgreSQL CVE with its CVSS v3 base score and vector,
-- typed from the raw scrape. The base score sniffs to VARCHAR upstream
-- (the source's auto_type_candidates omit a numeric type so version strings
-- can't collapse), so cast it here to DECIMAL(3,1) -- CVSS base scores are
-- exact one-decimal values (0.0-10.0), not floating-point measurements, so a
-- DECIMAL stores them exactly and the band range join compares them exactly.
-- severity_band and its display order
-- come from the cvss_severity_bands seed via a range join on the score --
-- the seed owns the NONE/LOW/MEDIUM/HIGH/CRITICAL thresholds so they live in
-- exactly one place (fct_fixes carries the worst CVE's band per fix). Empty scores (a listed
-- CVE with no CVSS) become NULL and match no band.
WITH typed AS (
  SELECT
    cve_id,
    NULLIF(component, '') AS component,
    NULLIF(cvss_base_score, '')::DECIMAL(3, 1) AS cvss_base_score,
    NULLIF(cvss_vector, '') AS cvss_vector
  FROM {{ source('scraped', 'cve_severity') }}
)

SELECT
  typed.cve_id,
  typed.component,
  typed.cvss_base_score,
  typed.cvss_vector,
  bands.severity_band,
  bands.severity_band_order
FROM typed
LEFT JOIN {{ ref('cvss_severity_bands') }} AS bands
  ON
    typed.cvss_base_score >= bands.min_base_score
    AND typed.cvss_base_score <= COALESCE(bands.max_base_score, typed.cvss_base_score)
