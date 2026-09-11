-- Major-line dimension: one row per PostgreSQL development line -- the released
-- majors (their stable branches, e.g. PG18), the in-progress major (branched and
-- in beta, e.g. PG19), PLUS master, the development trunk. The single home for
-- line-level attributes: display label, branch name, the ~5-year support window
-- (ga_dt -> eol_dt), and lifecycle (released / beta / development). is_released
-- separates the released majors; is_supported is the released-and-still-in-window
-- subset. Every commit's branch value resolves to a real row (no NULL/Unknown
-- FK). Sourced from int_major_development, which discovers released AND
-- in-progress majors from the repo, with ga_dt from int_versions and master
-- appended. dim_major_key is a generate_surrogate_key hash of the natural key;
-- conforms to dim_version, dim_commit, fct_branch_size_weekly,
-- fct_major_development. Grain = major line. -> data/derived/dim_major.csv
WITH ga_dates AS (
  SELECT
    major,
    MIN(release_dt) AS ga_dt
  FROM {{ ref('int_versions') }}
  GROUP BY major
),

real_members AS (
  SELECT
    {{ dbt_utils.generate_surrogate_key(['smd.major']) }} AS dim_major_key,
    smd.major,
    'PG' || smd.major AS major_label,
    'REL_' || smd.major || '_STABLE' AS stable_branch,
    -- released majors have a GA day; the in-progress major has not shipped yet
    COALESCE(gad.ga_dt, DATE '{{ var('future_eternity') }}') AS ga_dt,
    -- ~5-year support window: major M's final minor lands ~Nov of 2012 + M
    MAKE_DATE(smd.major + 2012, 11, 30) AS eol_dt,
    smd.dev_status = 'released' AS is_released,
    smd.dev_status = 'released' AND {{ as_of_date() }} <= MAKE_DATE(smd.major + 2012, 11, 30) AS is_supported,
    smd.dev_status AS lifecycle,
    false AS is_synthetic_row
  FROM {{ ref('int_major_development') }} AS smd
  LEFT JOIN ga_dates AS gad ON smd.major = gad.major
)

-- explicit projection (not SELECT *): dct validate derives each model's
-- columns statically from this SQL to check the faces' queries against them
SELECT
  dim_major_key,
  major,
  major_label,
  stable_branch,
  ga_dt,
  eol_dt,
  is_released,
  is_supported,
  lifecycle,
  is_synthetic_row
FROM real_members
UNION ALL
-- master: the development trunk (the major AFTER the in-progress one) -- no
-- numbered major, GA, or EOL yet.
SELECT
  {{ dbt_utils.generate_surrogate_key(["'master'"]) }} AS dim_major_key,
  null AS major,
  'master' AS major_label,
  'master' AS stable_branch,
  DATE '{{ var('future_eternity') }}' AS ga_dt,
  DATE '{{ var('future_eternity') }}' AS eol_dt,
  false AS is_released,
  false AS is_supported,
  'development' AS lifecycle,
  -- master is the real development trunk, not a synthetic placeholder
  false AS is_synthetic_row
UNION ALL
SELECT
  {{ unknown_key() }} AS dim_major_key,
  null AS major,
  '(unknown)' AS major_label,
  '(unknown)' AS stable_branch,
  DATE '{{ var('past_eternity') }}' AS ga_dt,
  DATE '{{ var('future_eternity') }}' AS eol_dt,
  false AS is_released,
  false AS is_supported,
  '(unknown)' AS lifecycle,
  true AS is_synthetic_row
UNION ALL
SELECT
  {{ not_applicable_key() }} AS dim_major_key,
  null AS major,
  '(not applicable)' AS major_label,
  '(not applicable)' AS stable_branch,
  DATE '{{ var('past_eternity') }}' AS ga_dt,
  DATE '{{ var('future_eternity') }}' AS eol_dt,
  false AS is_released,
  false AS is_supported,
  '(not applicable)' AS lifecycle,
  true AS is_synthetic_row
