-- Version dimension: one row per individual PostgreSQL release (e.g. 18.6),
-- the grain BELOW a release wave. A wave (dim_release) is the same-day group of
-- minors shipped across branches; this dimension is the single minor tag within
-- it. Sourced from the git-tag registry (int_releases), which covers every
-- REL_MAJOR_MINOR incl. the .0 majors that ship alone (not in a minor wave).
--
--   is_major_release   the .0 tag that opens a major line (minor = 0)
--   dim_release_key    the wave this minor shipped in (dim_release's PK);
--                      NULL for the .0 majors, which ship by themselves
--
-- dim_version_key is a generate_surrogate_key hash of `version`, the PK facts
-- conform on: fct_fixes (the representative minor of a deduped fix) and
-- fct_version_items_agg (changelog item count per minor).
-- Grain = version. -> ../data/derived/dim_version.csv
SELECT
  {{ dbt_utils.generate_surrogate_key(['rel.version']) }} AS dim_version_key,
  rel.version,
  rel.major,
  rel.minor,
  rel.minor = 0 AS is_major_release,
  rel.wrap_dt,
  rel.release_dt,
  drl.dim_release_key
FROM {{ ref('int_releases') }} AS rel
LEFT JOIN {{ ref('dim_release') }} AS drl ON rel.release_dt = drl.release_dt
