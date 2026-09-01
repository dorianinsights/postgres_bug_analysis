-- Version dimension: one row per individual PostgreSQL release (e.g. 18.6),
-- the grain BELOW a release. A release (dim_release) is the same-day group of
-- minors shipped across branches; this dimension is the single minor tag within
-- it. Sourced from the git-tag registry (int_versions), which covers every
-- REL_MAJOR_MINOR incl. the .0 majors that ship alone (not in a minor release).
--
--   is_major_release   the .0 tag that opens a major line (minor = 0)
--   dim_release_key    the release this minor shipped in -- resolved by joining
--                      int_releases (the release registry, which mints the key),
--                      NOT by reaching back into dim_release. Not Applicable for
--                      the .0 majors, which ship by themselves.
--
-- dim_version_key is a generate_surrogate_key hash of `version`, the PK facts
-- conform on: fct_fixes (the representative minor of a deduped fix) and
-- fct_version_items_agg (changelog item count per minor).
-- Grain = version. -> ../data/derived/dim_version.csv
WITH real_members AS (
  SELECT
    {{ dbt_utils.generate_surrogate_key(['rel.version']) }} AS dim_version_key,
    rel.version,
    rel.major,
    rel.minor,
    rel.minor = 0 AS is_major_release,
    rel.wrap_dt,
    rel.release_dt,
    COALESCE(irl.dim_release_key, {{ not_applicable_key() }}) AS dim_release_key
  FROM {{ ref('int_versions') }} AS rel
  LEFT JOIN {{ ref('int_releases') }} AS irl ON rel.release_dt = irl.release_dt
)

SELECT * FROM real_members
UNION ALL
SELECT
  {{ unknown_key() }} AS dim_version_key,
  '(unknown)' AS version,
  null AS major,
  null AS minor,
  false AS is_major_release,
  DATE '{{ var('past_eternity') }}' AS wrap_dt,
  DATE '{{ var('past_eternity') }}' AS release_dt,
  {{ unknown_key() }} AS dim_release_key
UNION ALL
SELECT
  {{ not_applicable_key() }} AS dim_version_key,
  '(not applicable)' AS version,
  null AS major,
  null AS minor,
  false AS is_major_release,
  DATE '{{ var('past_eternity') }}' AS wrap_dt,
  DATE '{{ var('past_eternity') }}' AS release_dt,
  {{ not_applicable_key() }} AS dim_release_key
