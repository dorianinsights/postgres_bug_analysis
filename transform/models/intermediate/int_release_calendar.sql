-- The scheduled minor-release calendar: PostgreSQL minors ship on the
-- second Thursday of Feb/May/Aug/Nov, and the tarballs are wrapped
-- (tagged) the Monday before — the hard content cutoff. Computed from
-- the rule rather than observed tags so it extends one release into the
-- FUTURE (attribution needs "the next wrap" before it happens); the
-- assert_release_calendar_matches_observed_wraps singular test pins the
-- computed wraps to the tag-derived cycle starts where both exist.
-- Out-of-band emergency releases are not on this calendar by design.
WITH month_starts AS (
  SELECT gsr.month_start::DATE AS month_start
  FROM GENERATE_SERIES(
    DATE '2021-11-01',
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
