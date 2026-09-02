-- Which shipped minor each commit belongs to: the commit's branch gives the
-- major, and the scheduled-release window (previous wrap, this wrap] containing
-- the commit's UTC day gives the release; their intersection is the minor
-- version. master, out-of-band, and not-yet-shipped commits resolve to NULL. This
-- is the SINGLE home for the commit -> version (and -> ship release) mapping:
-- fct_commits reads it for its dim_release_key / dim_version_key, and dim_version
-- reads it (aggregated) for the first/last commit of each version. Windows come
-- from int_releases (minor releases only, OOB excluded), matching the cycle
-- windows the fix counts on dim_release are built from, so commit counts
-- reconcile. Grain = (branch, commit_hash).
WITH windows AS (
  SELECT
    release_dt,
    COALESCE(LAG(wrap_dt) OVER (ORDER BY wrap_dt), DATE '{{ var('past_eternity') }}') AS win_start,
    wrap_dt AS win_end
  FROM {{ ref('int_releases') }}
  WHERE NOT is_out_of_band AND wrap_dt IS NOT null
)

SELECT
  gcm.branch,
  gcm.commit_hash,
  gcm.commit_ts,
  gcm.commit_dt,
  wnd.release_dt AS ship_release_dt,
  ver.version
FROM {{ ref('stg_git_commits') }} AS gcm
LEFT JOIN windows AS wnd
  ON
    gcm.commit_dt > wnd.win_start
    AND gcm.commit_dt <= wnd.win_end
    AND gcm.branch != 'master'
LEFT JOIN {{ ref('int_versions') }} AS ver
  ON
    wnd.release_dt = ver.release_dt
    AND TRY_CAST(SPLIT_PART(gcm.branch, '_', 2) AS INTEGER) = ver.major
