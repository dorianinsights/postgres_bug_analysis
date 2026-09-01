-- The authoritative release registry, sourced from git release tags (the same
-- postgres.git clone the commit models read) rather than the SGML release
-- notes. One row per REL_MAJOR_MINOR tag (stg_git_tags already drops BETA/RC).
--
-- release_dt is the ANNOUNCED release day, always a Thursday: PostgreSQL wraps
-- the tarball Mon-Wed and ships the first Thursday on/after the wrap, so we snap
-- the tag's wrap date forward to that Thursday (ISODOW 4). This reproduces the
-- old SGML <date> EXACTLY for every corpus release -- scheduled, out-of-band,
-- and .0 majors alike -- and covers the out-of-band releases that the quarterly
-- int_release_calendar deliberately omits. Grain = version.
WITH wraps AS (
  SELECT
    major::VARCHAR || '.' || minor::VARCHAR AS version,
    major,
    minor,
    (tag_ts AT TIME ZONE 'utc')::DATE AS wrap_dt
  FROM {{ ref('stg_git_tags') }}
)

SELECT
  version,
  major,
  minor,
  wrap_dt,
  -- ISODOW arithmetic yields BIGINT; DATE + n needs INTEGER
  wrap_dt + (((4 - ISODOW(wrap_dt)) + 7) % 7)::INTEGER AS release_dt
FROM wraps
