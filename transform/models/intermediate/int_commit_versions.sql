-- Which shipped minor each commit belongs to: the commit's branch gives the
-- major, and the release window (previous wrap, this wrap] containing the
-- commit's UTC day gives the release; their intersection is the minor version.
-- master and not-yet-shipped commits resolve to NULL. This is the SINGLE home for
-- the commit -> version (and -> ship release) mapping: fct_commits reads it for
-- its dim_release_key / dim_version_key, and dim_version reads it (aggregated) for
-- the first/last commit of each version.
--
-- Out-of-band emergency re-releases ARE included in the windows: an OOB release
-- is a real tag on the stable branch, so the commits up to its wrap genuinely
-- shipped in it and must not be folded into the next scheduled release (that left
-- every OOB minor with a NULL commit span even though it shipped fixes). This is
-- a version-assignment question and is deliberately independent of the CYCLE
-- analysis (int_release_cycles), which excludes OOB because an emergency
-- re-release is not a scheduled quarterly cycle. Grain = (branch, commit_hash).
WITH version_wraps AS (
  -- an OOB emergency re-release has no scheduled calendar wrap (so int_releases
  -- leaves its wrap_dt NULL), but it DOES carry a real wrap tag on the version --
  -- use that so the OOB release still gets a window.
  SELECT
    release_dt,
    MAX(wrap_dt) AS wrap_dt
  FROM {{ ref('int_versions') }}
  WHERE minor > 0 AND wrap_dt IS NOT null
  GROUP BY release_dt
),

release_wraps AS (
  -- every release's wrap boundary: the scheduled calendar wrap (incl. the upcoming
  -- open release, so in-flight commits still resolve their ship release), falling
  -- back to the version's wrap tag for OOB re-releases.
  SELECT
    irl.release_dt,
    COALESCE(irl.wrap_dt, vwr.wrap_dt) AS wrap_dt
  FROM {{ ref('int_releases') }} AS irl
  LEFT JOIN version_wraps AS vwr ON irl.release_dt = vwr.release_dt
),

windows AS (
  SELECT
    release_dt,
    COALESCE(LAG(wrap_dt) OVER (ORDER BY wrap_dt), DATE '{{ var('past_eternity') }}') AS win_start,
    wrap_dt AS win_end
  FROM release_wraps
  WHERE wrap_dt IS NOT null
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
