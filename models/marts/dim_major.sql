{% set columns = [
  'dim_major_key', 'major', 'major_label', 'stable_branch', 'ga_dt', 'eol_dt',
  'is_released', 'is_supported', 'lifecycle', 'is_synthetic_row',
] %}

WITH ga_dates AS (
  SELECT
    major,
    MIN(release_dt) AS ga_dt
  FROM {{ ref('int_versions') }}
  GROUP BY major
)

SELECT
  {{ dbt_utils.generate_surrogate_key(['smd.major']) }} AS dim_major_key,
  smd.major,
  smd.major_label,
  'REL_' || smd.major || '_STABLE' AS stable_branch,
  COALESCE(gad.ga_dt, {{ future_eternity_dt() }}) AS ga_dt,
  {{ major_eol_dt('smd.major') }} AS eol_dt,
  smd.dev_status = 'released' AS is_released,
  smd.dev_status = 'released' AND {{ as_of_date() }} <= {{ major_eol_dt('smd.major') }} AS is_supported,
  smd.dev_status AS lifecycle,
  false AS is_synthetic_row
FROM {{ ref('int_major_development') }} AS smd
LEFT JOIN ga_dates AS gad ON smd.major = gad.major
UNION ALL
-- master: the development trunk (the major after the in-progress one)
SELECT
  {{ dbt_utils.generate_surrogate_key(["'master'"]) }} AS dim_major_key,
  null AS major,
  'master' AS major_label,
  'master' AS stable_branch,
  {{ future_eternity_dt() }} AS ga_dt,
  {{ future_eternity_dt() }} AS eol_dt,
  false AS is_released,
  false AS is_supported,
  'development' AS lifecycle,
  false AS is_synthetic_row
{{ special_member_rows(
  'dim_major_key', columns,
  unknown={
    'major_label': "'(unknown)'", 'stable_branch': "'(unknown)'", 'ga_dt': past_eternity_dt(),
    'eol_dt': future_eternity_dt(), 'is_released': 'false', 'is_supported': 'false',
    'lifecycle': "'(unknown)'",
  },
  not_applicable={
    'major_label': "'(not applicable)'", 'stable_branch': "'(not applicable)'",
    'ga_dt': past_eternity_dt(), 'eol_dt': future_eternity_dt(), 'is_released': 'false',
    'is_supported': 'false', 'lifecycle': "'(not applicable)'",
  },
) }}
