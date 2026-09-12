WITH grouped AS (
  SELECT
    release_dt,
    STRING_AGG(version, ' / ' ORDER BY major, minor) AS versions,
    COUNT(*) AS release_cnt,
    MAX(item_cnt) < {{ var('scheduled_release_min_items') }} AS is_out_of_band
  FROM {{ ref('int_versions') }}
  WHERE minor > 0
  GROUP BY ALL
),

version_wraps AS (
  -- an out-of-band re-release has no scheduled calendar wrap (int_release_calendar
  -- is the quarterly cadence only), but each of its versions carries a real wrap
  -- tag -- use it so OOB releases get a wrap_dt too, consistent with dim_version.
  SELECT
    release_dt,
    MAX(wrap_dt) AS wrap_dt
  FROM {{ ref('int_versions') }}
  WHERE minor > 0 AND wrap_dt IS NOT null
  GROUP BY release_dt
),

shipped AS (
  SELECT
    grp.release_dt,
    COALESCE(cal.wrap_dt, vwr.wrap_dt) AS wrap_dt,
    'shipped' AS status,
    grp.versions,
    grp.release_cnt,
    grp.is_out_of_band,
    grp.release_dt = MIN(grp.release_dt) OVER () AS is_partial_window
  FROM grouped AS grp
  LEFT JOIN {{ ref('int_release_calendar') }} AS cal ON grp.release_dt = cal.scheduled_release_dt
  LEFT JOIN version_wraps AS vwr ON grp.release_dt = vwr.release_dt
),

-- the latest tagged release: everything scheduled after it is upcoming
latest_shipped AS (
  SELECT MAX(release_dt) AS release_dt
  FROM grouped
),

next_release AS (
  SELECT MIN(cal.scheduled_release_dt) AS release_dt
  FROM {{ ref('int_release_calendar') }} AS cal
  WHERE cal.scheduled_release_dt > (SELECT lsh.release_dt FROM latest_shipped AS lsh)
),

-- each active major's next minor is its latest release tag's minor + 1; the
-- Nth upcoming release adds N (open = +1, the release after = +2, ...)
active_majors AS (
  SELECT
    major,
    MAX(minor) AS latest_minor
  FROM {{ ref('int_versions') }}
  GROUP BY major
),

upcoming_dates AS (
  SELECT
    cal.scheduled_release_dt AS release_dt,
    cal.wrap_dt,
    CASE WHEN cal.scheduled_release_dt = nxt.release_dt THEN 'open' ELSE 'future' END AS status,
    ROW_NUMBER() OVER (ORDER BY cal.scheduled_release_dt) AS release_offset
  FROM {{ ref('int_release_calendar') }} AS cal, next_release AS nxt
  WHERE cal.scheduled_release_dt > (SELECT lsh.release_dt FROM latest_shipped AS lsh)
),

upcoming AS (
  SELECT
    udt.release_dt,
    udt.wrap_dt,
    udt.status,
    STRING_AGG(amj.major || '.' || (amj.latest_minor + udt.release_offset), ' / ' ORDER BY amj.major) AS versions,
    COUNT(*)::BIGINT AS release_cnt,
    false AS is_out_of_band,
    false AS is_partial_window
  FROM upcoming_dates AS udt
  CROSS JOIN active_majors AS amj
  -- only while the major is still supported, else an EOL major gets phantom
  -- future minors
  WHERE udt.release_dt <= {{ major_eol_dt('amj.major') }}
  GROUP BY udt.release_dt, udt.wrap_dt, udt.status
),

combined AS (
  SELECT * FROM shipped
  UNION ALL
  SELECT * FROM upcoming
)

SELECT
  {{ dbt_utils.generate_surrogate_key(['cmb.release_dt']) }} AS dim_release_key,
  cmb.release_dt,
  cmb.wrap_dt,
  cmb.status,
  cmb.versions,
  cmb.release_cnt,
  cmb.is_out_of_band,
  cmb.is_partial_window,
  -- announced = its release day has arrived; false for a just-tagged release
  -- in the wrap-to-Thursday window and for every upcoming release
  cmb.release_dt <= {{ as_of_date() }} AS is_announced,
  -- the scheduled release day this release's CYCLE ships at: itself for a
  -- scheduled (or upcoming) release; for an out-of-band re-release, which ships
  -- mid-cycle, the NEXT scheduled release. Cycle-grain measures
  -- (int_release_cycles, the projection comparators) fold an emergency
  -- release's fixes into the cycle that produced them through this column,
  -- while release-grain measures keep the exact release.
  CASE
    WHEN cmb.is_out_of_band
      THEN (
        SELECT MIN(cal.scheduled_release_dt)
        FROM {{ ref('int_release_calendar') }} AS cal
        WHERE cal.scheduled_release_dt >= cmb.release_dt
      )
    ELSE cmb.release_dt
  END AS cycle_ships_at_dt
FROM combined AS cmb
