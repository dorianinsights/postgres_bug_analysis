SELECT
  cve.cve_id,
  NULLIF(cve.component, '') AS component,
  -- an empty score becomes NULL so the not_null test fails, not the cast
  NULLIF(cve.cvss_base_score, '')::DECIMAL(3, 1) AS cvss_base_score,
  NULLIF(cve.cvss_vector, '') AS cvss_vector,
  bands.severity_band,
  bands.severity_band_order
FROM {{ source('scraped', 'cve_severity') }} AS cve
-- the typed score again: a lateral alias can't be used in a join condition
LEFT OUTER JOIN {{ ref('cvss_severity_bands') }} AS bands
  ON {{ in_range("NULLIF(cve.cvss_base_score, '')::DECIMAL(3, 1)", 'bands.min_base_score', 'bands.max_base_score') }}
