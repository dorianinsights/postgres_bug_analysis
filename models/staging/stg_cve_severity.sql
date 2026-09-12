WITH typed AS (
  SELECT
    cve_id,
    NULLIF(component, '') AS component,
    -- an empty score becomes NULL so the not_null test fails, not the cast
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
  ON {{ in_range('typed.cvss_base_score', 'bands.min_base_score', 'bands.max_base_score') }}
