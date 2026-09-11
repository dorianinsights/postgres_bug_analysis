-- CVE dimension: one row per CVE referenced by a corpus fix, with its CVSS v3
-- severity where PostgreSQL publishes it. Scoped to the CVEs the fixes actually
-- cite (from int_fix_reps.cves) rather than every published CVE, so it conforms
-- exactly to what the facts/bridges reference. The two long-EOL CVEs the
-- security page no longer lists stay here with NULL severity. Plus the two
-- Kimball special members (Unknown / Not Applicable). Grain = dim_cve_key.
-- -> data/derived/dim_cve.csv
WITH corpus_cves AS (
  SELECT DISTINCT cve_id
  FROM {{ ref('int_fix_cves') }}
),

real_members AS (
  SELECT
    {{ dbt_utils.generate_surrogate_key(['cvs.cve_id']) }} AS dim_cve_key,
    cvs.cve_id,
    sev.cvss_base_score,
    sev.severity_band,
    sev.severity_band_order,
    sev.cvss_vector,
    sev.component,
    sev.cve_id IS null AS is_severity_unlisted,
    false AS is_synthetic_row
  FROM corpus_cves AS cvs
  LEFT JOIN {{ ref('stg_cve_severity') }} AS sev ON cvs.cve_id = sev.cve_id
)

-- explicit projection (not SELECT *): dct validate derives each model's
-- columns statically from this SQL to check the faces' queries against them
SELECT
  dim_cve_key,
  cve_id,
  cvss_base_score,
  severity_band,
  severity_band_order,
  cvss_vector,
  component,
  is_severity_unlisted,
  is_synthetic_row
FROM real_members
UNION ALL
SELECT
  {{ unknown_key() }} AS dim_cve_key,
  '(unknown)' AS cve_id,
  null AS cvss_base_score,
  null AS severity_band,
  null AS severity_band_order,
  null AS cvss_vector,
  null AS component,
  true AS is_severity_unlisted,
  true AS is_synthetic_row
UNION ALL
SELECT
  {{ not_applicable_key() }} AS dim_cve_key,
  '(not applicable)' AS cve_id,
  null AS cvss_base_score,
  null AS severity_band,
  null AS severity_band_order,
  null AS cvss_vector,
  null AS component,
  true AS is_severity_unlisted,
  true AS is_synthetic_row
