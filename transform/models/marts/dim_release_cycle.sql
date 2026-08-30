-- Release-cycle dimension: one row per development cycle — the period from a
-- wrap (content cutoff) to the release it ships — computed from the release
-- calendar, so it covers every cycle including the OPEN one and near-future
-- ones that no shipped wave exists for yet. cycle_key is the shipping release's
-- date_key. A wave is the shipped form of a cycle (dim_release_wave relates
-- here via cycle_key); fct_release_cycles is the cycle-grain fact. Grain =
-- cycle_key. -> ../data/derived/dim_release_cycle.csv
WITH cycles AS (
  SELECT
    wrap_dt AS cycle_start_dt,
    LEAD(scheduled_release_dt) OVER (ORDER BY wrap_dt) AS ships_at_dt
  FROM {{ ref('int_release_calendar') }}
)

SELECT
  STRFTIME(ships_at_dt, '%Y%m%d')::INTEGER AS cycle_key,
  cycle_start_dt,
  ships_at_dt,
  STRFTIME(cycle_start_dt, '%Y%m%d')::INTEGER AS cycle_start_date_key,
  cycle_start_dt <= CURRENT_DATE AND ships_at_dt > CURRENT_DATE AS is_open,
  ships_at_dt <= CURRENT_DATE AS is_shipped
FROM cycles
WHERE ships_at_dt IS NOT null
