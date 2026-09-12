{% set columns = [
  'dim_cve_key', 'cve_id', 'cvss_base_score', 'severity_band', 'severity_band_order',
  'cvss_vector', 'component', 'is_severity_unlisted', 'is_synthetic_row',
] %}

WITH corpus_cves AS (
  SELECT DISTINCT cve_id
  FROM {{ ref('int_fix_cves') }}
)

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
{{ special_member_rows(
  'dim_cve_key', columns,
  unknown={'cve_id': "'(unknown)'", 'is_severity_unlisted': 'true'},
  not_applicable={'cve_id': "'(not applicable)'", 'is_severity_unlisted': 'true'},
) }}
