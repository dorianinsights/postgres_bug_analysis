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
-- conform on (e.g. fct_fixes, the representative minor of a deduped fix).
-- item_cnt (the parsed changelog-item count per minor) is folded onto this row
-- 1:1 -- like dim_release's cycle signals -- rather than kept as a separate
-- one-measure fact; it is NULL for the .0 majors and the special members, which
-- have no release-note items.
-- Grain = version. -> ../data/derived/dim_version.csv
WITH item_counts AS (
  SELECT
    version,
    COUNT(*)::BIGINT AS item_cnt
  FROM {{ ref('stg_release_items') }}
  GROUP BY ALL
),

real_members AS (
  SELECT
    {{ dbt_utils.generate_surrogate_key(['rel.version']) }} AS dim_version_key,
    rel.version,
    rel.major,
    COALESCE(dmj.dim_major_key, {{ unknown_key() }}) AS dim_major_key,
    rel.minor,
    rel.minor = 0 AS is_major_release,
    rel.wrap_dt,
    rel.release_dt,
    COALESCE(irl.dim_release_key, {{ not_applicable_key() }}) AS dim_release_key,
    itc.item_cnt,
    -- inherited from the version's release: a release is out-of-band (emergency
    -- re-release) when its LARGEST minor has fewer than
    -- var(scheduled_release_min_items) items -- a release-group property, so read
    -- it here rather than re-deriving it per-version from item_cnt (which is
    -- wrong: a small minor inside a normal release is not out-of-band).
    COALESCE(irl.is_out_of_band, false) AS is_out_of_band
  FROM {{ ref('int_versions') }} AS rel
  LEFT JOIN {{ ref('int_releases') }} AS irl ON rel.release_dt = irl.release_dt
  LEFT JOIN {{ ref('dim_major') }} AS dmj ON rel.major = dmj.major
  LEFT JOIN item_counts AS itc ON rel.version = itc.version
)

SELECT * FROM real_members
UNION ALL
SELECT
  {{ unknown_key() }} AS dim_version_key,
  '(unknown)' AS version,
  null AS major,
  {{ unknown_key() }} AS dim_major_key,
  null AS minor,
  false AS is_major_release,
  DATE '{{ var('past_eternity') }}' AS wrap_dt,
  DATE '{{ var('past_eternity') }}' AS release_dt,
  {{ unknown_key() }} AS dim_release_key,
  null AS item_cnt,
  false AS is_out_of_band
UNION ALL
SELECT
  {{ not_applicable_key() }} AS dim_version_key,
  '(not applicable)' AS version,
  null AS major,
  {{ not_applicable_key() }} AS dim_major_key,
  null AS minor,
  false AS is_major_release,
  DATE '{{ var('past_eternity') }}' AS wrap_dt,
  DATE '{{ var('past_eternity') }}' AS release_dt,
  {{ not_applicable_key() }} AS dim_release_key,
  null AS item_cnt,
  false AS is_out_of_band
