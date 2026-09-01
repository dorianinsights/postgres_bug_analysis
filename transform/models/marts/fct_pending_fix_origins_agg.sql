-- Distinct pending fixes (committed toward the next minor, not yet
-- released) rolled up by origin — the source breakdown of the in-progress
-- November release the origins face appends to the historical "fix origins
-- per release" chart. Carries the cutoff dates as context (as_of_dt is the
-- build date; the counts grow until wrap_dt). fix_share is each origin's share
-- of the pending total (a ratio, so DECIMAL not float), moved off the chart.
-- Grain = (ships_at_dt, origin). Note: no security bucket here — embargoed
-- security work only lands in public git on wrap day, so the pending set can't
-- see it yet.
WITH ships AS (
  SELECT
    (
      SELECT MAX(wrap_dt) FROM {{ ref('int_release_calendar') }}
      WHERE wrap_dt <= CURRENT_DATE)
      AS wrap_dt,
    (
      SELECT MIN(scheduled_release_dt) FROM {{ ref('int_release_calendar') }}
      WHERE scheduled_release_dt > CURRENT_DATE)
      AS ships_at_dt
),

agg AS (
  SELECT
    ships.ships_at_dt,
    ships.wrap_dt,
    CURRENT_DATE AS as_of_dt,
    pnd.origin,
    COUNT(*)::BIGINT AS fix_cnt
  FROM {{ ref('int_pending_fixes') }} AS pnd, ships
  GROUP BY ALL
)

SELECT
  ships_at_dt,
  wrap_dt,
  as_of_dt,
  origin,
  fix_cnt,
  (fix_cnt::DECIMAL(18, 6) / NULLIF(SUM(fix_cnt) OVER (), 0))::DECIMAL(7, 6) AS fix_share
FROM agg
