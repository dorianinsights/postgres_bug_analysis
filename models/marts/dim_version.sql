{% set columns = [
  'dim_version_key', 'dim_major_key', 'dim_release_key', 'version', 'major', 'minor',
  'is_major_release', 'wrap_dt', 'release_dt', 'item_cnt', 'is_out_of_band', 'first_commit_dt',
  'first_commit_ts', 'first_commit_hash', 'last_commit_dt', 'last_commit_ts', 'last_commit_hash',
  'is_synthetic_row',
] %}

-- first / last commit of each version: the backpatch commits that shipped in a
-- minor, or the major's whole development for a .0
WITH commit_span AS (
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
)

SELECT
  {{ dbt_utils.generate_surrogate_key(['rel.version']) }} AS dim_version_key,
  COALESCE(dmj.dim_major_key, {{ unknown_key() }}) AS dim_major_key,
  -- the release this minor shipped in; the .0 majors ship by themselves
  COALESCE(irl.dim_release_key, {{ not_applicable_key() }}) AS dim_release_key,
  rel.version,
  rel.major,
  rel.minor,
  rel.minor = 0 AS is_major_release,
  rel.wrap_dt,
  rel.release_dt,
  rel.item_cnt,
  -- a release-group property: a small minor inside a normal release is not out-of-band
  COALESCE(irl.is_out_of_band, false) AS is_out_of_band,
  csp.first_commit_dt,
  csp.first_commit_ts,
  csp.first_commit_hash,
  csp.last_commit_dt,
  csp.last_commit_ts,
  csp.last_commit_hash,
  false AS is_synthetic_row
FROM {{ ref('int_versions') }} AS rel
LEFT JOIN {{ ref('int_releases') }} AS irl ON rel.release_dt = irl.release_dt
LEFT JOIN {{ ref('dim_major') }} AS dmj ON rel.major = dmj.major
LEFT JOIN commit_span AS csp ON rel.version = csp.version
UNION ALL
-- the in-progress major's GA-to-be (e.g. 19.0): its release is the matching
-- in_development row in dim_release (same key)
SELECT
  {{ dbt_utils.generate_surrogate_key(["smd.major || '.0'"]) }} AS dim_version_key,
  dmj.dim_major_key,
  {{ dbt_utils.generate_surrogate_key(["smd.major || '.0'"]) }} AS dim_release_key,
  smd.major || '.0' AS version,
  smd.major,
  0 AS minor,
  true AS is_major_release,
  {{ future_eternity_dt() }} AS wrap_dt,
  {{ future_eternity_dt() }} AS release_dt,
  null AS item_cnt,
  false AS is_out_of_band,
  smd.first_dev_commit_dt AS first_commit_dt,
  smd.first_dev_commit_ts AS first_commit_ts,
  smd.first_dev_commit_hash AS first_commit_hash,
  smd.last_dev_commit_dt AS last_commit_dt,
  smd.last_dev_commit_ts AS last_commit_ts,
  smd.last_dev_commit_hash AS last_commit_hash,
  false AS is_synthetic_row
FROM {{ ref('int_major_development') }} AS smd
INNER JOIN {{ ref('dim_major') }} AS dmj ON smd.major = dmj.major
WHERE smd.dev_status = 'beta'
{{ special_member_rows(
  'dim_version_key', columns,
  unknown={
    'dim_major_key': unknown_key(), 'dim_release_key': unknown_key(), 'version': "'(unknown)'",
    'is_major_release': 'false', 'wrap_dt': past_eternity_dt(), 'release_dt': past_eternity_dt(),
    'is_out_of_band': 'false',
  },
  not_applicable={
    'dim_major_key': not_applicable_key(), 'dim_release_key': not_applicable_key(),
    'version': "'(not applicable)'", 'is_major_release': 'false',
    'wrap_dt': past_eternity_dt(), 'release_dt': past_eternity_dt(), 'is_out_of_band': 'false',
  },
) }}
