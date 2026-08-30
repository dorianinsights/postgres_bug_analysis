-- Every CLOSED release cycle replayed at the current cycle's age: the three
-- early signals vs the wave that shipped — the like-for-like base for the
-- linear projections. A thin projection of int_cycle_signals (which computes
-- the windowed signals for all cycles); this keeps only the closed cycles with
-- all three signals present, so the shipped-per-signal ratios never divide by
-- zero. Scheduled waves only (out-of-band and the partial first wave excluded,
-- via int_cycle_signals' shipped join).
SELECT
  ships_at_dt,
  window_days,
  shipped_fix_cnt,
  early_report_cnt,
  early_message_cnt,
  early_fix_cnt
FROM {{ ref('int_cycle_signals') }}
WHERE
  shipped_fix_cnt IS NOT null
  AND early_report_cnt > 0
  AND early_message_cnt > 0
  AND early_fix_cnt > 0
