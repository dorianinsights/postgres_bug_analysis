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

-- first / last commit that shipped in each minor, from the commit->version map
-- (stable-branch commits only; NULL for the .0 majors, which have no in-window
-- backpatch commits, and for the special members)
commit_span AS (
  SELECT
    version,
    MIN(commit_dt) AS first_commit_dt,
    MIN(commit_ts) AS first_commit_ts,
    ARG_MIN(commit_hash, commit_ts) AS first_commit_hash,
    MAX(commit_dt) AS last_commit_dt,
    MAX(commit_ts) AS last_commit_ts,
    ARG_MAX(commit_hash, commit_ts) AS last_commit_hash
  FROM {{ ref('int_commit_versions') }}
  WHERE version IS NOT null
  GROUP BY version
),

real_members AS (
  SELECT
    {{ dbt_utils.generate_surrogate_key(['rel.version']) }} AS dim_version_key,
    COALESCE(dmj.dim_major_key, {{ unknown_key() }}) AS dim_major_key,
    COALESCE(irl.dim_release_key, {{ not_applicable_key() }}) AS dim_release_key,
    rel.version,
    rel.major,
    rel.minor,
    rel.minor = 0 AS is_major_release,
    rel.wrap_dt,
    rel.release_dt,
    itc.item_cnt,
    -- inherited from the version's release: a release is out-of-band (emergency
    -- re-release) when its LARGEST minor has fewer than
    -- var(scheduled_release_min_items) items -- a release-group property, so read
    -- it here rather than re-deriving it per-version from item_cnt (which is
    -- wrong: a small minor inside a normal release is not out-of-band).
    COALESCE(irl.is_out_of_band, false) AS is_out_of_band,
    -- minors: the backpatch commits that shipped in the minor (csp). .0 majors:
    -- the major's whole feature development (smd, git tag ancestry) -- otherwise a
    -- .0 has no in-minor commits and would be NULL.
    COALESCE(csp.first_commit_dt, CASE WHEN rel.minor = 0 THEN smd.first_dev_commit_dt END) AS first_commit_dt,
    COALESCE(csp.first_commit_ts, CASE WHEN rel.minor = 0 THEN smd.first_dev_commit_ts END) AS first_commit_ts,
    COALESCE(csp.first_commit_hash, CASE WHEN rel.minor = 0 THEN smd.first_dev_commit_hash END) AS first_commit_hash,
    COALESCE(csp.last_commit_dt, CASE WHEN rel.minor = 0 THEN smd.last_dev_commit_dt END) AS last_commit_dt,
    COALESCE(csp.last_commit_ts, CASE WHEN rel.minor = 0 THEN smd.last_dev_commit_ts END) AS last_commit_ts,
    COALESCE(csp.last_commit_hash, CASE WHEN rel.minor = 0 THEN smd.last_dev_commit_hash END) AS last_commit_hash
  FROM {{ ref('int_versions') }} AS rel
  LEFT JOIN {{ ref('int_releases') }} AS irl ON rel.release_dt = irl.release_dt
  LEFT JOIN {{ ref('dim_major') }} AS dmj ON rel.major = dmj.major
  LEFT JOIN item_counts AS itc ON rel.version = itc.version
  LEFT JOIN commit_span AS csp ON rel.version = csp.version
  LEFT JOIN {{ ref('stg_major_development') }} AS smd ON rel.major = smd.major
),

-- the in-progress major's GA-to-be (e.g. 19.0): a first-class in-development
-- version whose "commits" are the major's feature development so far. No release
-- date yet (forward-looking); its release is the matching in_development row in
-- dim_release (same key).
in_dev_version AS (
  SELECT
    {{ dbt_utils.generate_surrogate_key(["smd.major || '.0'"]) }} AS dim_version_key,
    dmj.dim_major_key,
    {{ dbt_utils.generate_surrogate_key(["smd.major || '.0'"]) }} AS dim_release_key,
    smd.major || '.0' AS version,
    smd.major,
    0 AS minor,
    true AS is_major_release,
    DATE '{{ var('future_eternity') }}' AS wrap_dt,
    DATE '{{ var('future_eternity') }}' AS release_dt,
    null AS item_cnt,
    false AS is_out_of_band,
    smd.first_dev_commit_dt AS first_commit_dt,
    smd.first_dev_commit_ts AS first_commit_ts,
    smd.first_dev_commit_hash AS first_commit_hash,
    smd.last_dev_commit_dt AS last_commit_dt,
    smd.last_dev_commit_ts AS last_commit_ts,
    smd.last_dev_commit_hash AS last_commit_hash
  FROM {{ ref('stg_major_development') }} AS smd
  INNER JOIN {{ ref('dim_major') }} AS dmj ON smd.major = dmj.major
  WHERE smd.dev_status = 'beta'
)

SELECT * FROM real_members
UNION ALL
SELECT * FROM in_dev_version
UNION ALL
SELECT
  {{ unknown_key() }} AS dim_version_key,
  {{ unknown_key() }} AS dim_major_key,
  {{ unknown_key() }} AS dim_release_key,
  '(unknown)' AS version,
  null AS major,
  null AS minor,
  false AS is_major_release,
  DATE '{{ var('past_eternity') }}' AS wrap_dt,
  DATE '{{ var('past_eternity') }}' AS release_dt,
  null AS item_cnt,
  false AS is_out_of_band,
  null AS first_commit_dt,
  null AS first_commit_ts,
  null AS first_commit_hash,
  null AS last_commit_dt,
  null AS last_commit_ts,
  null AS last_commit_hash
UNION ALL
SELECT
  {{ not_applicable_key() }} AS dim_version_key,
  {{ not_applicable_key() }} AS dim_major_key,
  {{ not_applicable_key() }} AS dim_release_key,
  '(not applicable)' AS version,
  null AS major,
  null AS minor,
  false AS is_major_release,
  DATE '{{ var('past_eternity') }}' AS wrap_dt,
  DATE '{{ var('past_eternity') }}' AS release_dt,
  null AS item_cnt,
  false AS is_out_of_band,
  null AS first_commit_dt,
  null AS first_commit_ts,
  null AS first_commit_hash,
  null AS last_commit_dt,
  null AS last_commit_ts,
  null AS last_commit_hash
