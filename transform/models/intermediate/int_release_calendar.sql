-- The scheduled minor-release calendar: PostgreSQL minors ship on the
-- second Thursday of Feb/May/Aug/Nov, and the tarballs are wrapped
-- (tagged) the Monday before — the hard content cutoff. Computed from
-- the rule rather than observed tags so it extends one release into the
-- FUTURE (attribution needs "the next wrap" before it happens); the
-- assert_release_calendar_matches_observed_wraps singular test pins the
-- computed wraps to the tag-derived cycle starts where both exist.
-- Out-of-band emergency releases are not on this calendar by design.
WITH anchor AS (
  -- Anchor the grid on the corpus itself: February of the year BEFORE the
  -- earliest corpus release tag (the first .0 at/above FIRST_MAJOR). February is
  -- on the Feb/May/Aug/Nov grid, and a full year's head start guarantees the
  -- earliest corpus release has a prior scheduled cycle (its cycle_start_dt).
  -- Pre-corpus entries only supply cycle boundaries -- they never become
  -- releases (those come from tags) and int_release_cycles filters cycle
  -- signals to corpus releases. Derived, so the calendar moves with FIRST_MAJOR
  -- and carries no date literal; the relationships tests to dim_date guard
  -- that the fixed calendar spine still covers it.
  SELECT MAKE_DATE(YEAR(MIN(tag_dt)) - 1, 2, 1) AS grid_start
  FROM {{ ref('stg_git_tags') }}
),

month_starts AS (
  SELECT gsr.month_start::DATE AS month_start
  FROM anchor
  CROSS JOIN GENERATE_SERIES(
    anchor.grid_start,
    DATE_TRUNC('month', CURRENT_DATE + INTERVAL 6 MONTH),
    INTERVAL 3 MONTH
  ) AS gsr (month_start)
),

second_thursdays AS (
  -- DATE + n needs INTEGER; ISODOW arithmetic yields BIGINT
  SELECT
    month_start
    + (((4 - ISODOW(month_start) + 7) % 7) + 7)::INTEGER AS scheduled_release_dt
  FROM month_starts
)

SELECT
  scheduled_release_dt,
  scheduled_release_dt - 3 AS wrap_dt
FROM second_thursdays
