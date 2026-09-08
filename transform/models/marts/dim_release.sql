-- Release dimension: one row per PostgreSQL release, captured by `status`:
--   shipped  a past release (scheduled OR out-of-band) — actual measures
--   open     the in-flight cycle (its wrap has passed, ships next) — no measures
--   future   an upcoming scheduled release not yet started — no measures
-- The registry and the dim_release_key (minted once, upstream) come from
-- int_releases; the shipped fix/CVE/security measures from int_release_summary;
-- and the cycle signals (int_release_cycles, once a standalone
-- fct_release_cycles) fold onto the same row — a cycle IS a release earlier in
-- its life. They are non-NULL only for the started scheduled cycles. Projections
-- for the open/future releases live in their own conforming facts
-- (fix_projection_estimates, projections), not here. Plus the two Kimball
-- special members. Grain = dim_release_key. -> ../data/derived/dim_release.csv
WITH real_members AS (
  SELECT
    rel.dim_release_key,
    rel.release_dt,
    rel.wrap_dt,
    rel.status,
    rel.is_out_of_band,
    rel.is_partial_window,
    -- false for a just-tagged release until its announcement day, and for the
    -- open / future ones
    rel.is_announced,
    rel.versions,
    rel.release_cnt,
    rrs.distinct_fix_cnt,
    rrs.distinct_cve_cnt,
    rrs.security_fix_cnt,
    -- the committed-fix population that shipped in this release (distinct
    -- non-housekeeping stable-branch subjects) and how much of it the notes
    -- documented (distinct_fix_cnt / committed_fix_cnt); shipped rows only
    rrs.committed_fix_cnt,
    rrs.documentation_rate,
    -- cycle signals: non-NULL only for the started scheduled cycles, NULL for
    -- out-of-band releases and the not-yet-started future release
    irc.cycle_start_dt,
    irc.window_days,
    irc.early_report_cnt,
    irc.early_message_cnt,
    irc.early_fix_cnt,
    irc.full_fix_cnt,
    -- first_window_fix_cnt is the FIXED-window (seasonality_window_days) early
    -- count for the stable quarterly-seasonality view, vs early_fix_cnt's moving
    -- age window used by the projection
    irc.first_window_fix_cnt,
    -- the front-loading signal: the fraction of a cycle's backpatched fixes that
    -- land in that fixed first window (first_window_fix_cnt / full_fix_cnt). A
    -- ratio, so DECIMAL not float; NULL when the cycle has no full-window fixes
    -- (and on the non-cycle rows). The quarterly-seasonality chart averages it.
    (irc.first_window_fix_cnt::DECIMAL(15, 6) / NULLIF(irc.full_fix_cnt, 0))::DECIMAL(7, 6) AS early_fix_share,
    -- shipped-per-early-signal ratios at the open cycle's age -- the historical
    -- scaling factors the fix projection replays (fix_projection_estimates
    -- medians these). Ratios, so DECIMAL not float; NULL when the signal is 0
    -- or the cycle hasn't shipped (distinct_fix_cnt NULL).
    (rrs.distinct_fix_cnt::DECIMAL(15, 6) / NULLIF(irc.early_report_cnt, 0))::DECIMAL(12, 6) AS fix_per_early_report,
    (rrs.distinct_fix_cnt::DECIMAL(15, 6) / NULLIF(irc.early_message_cnt, 0))::DECIMAL(12, 6) AS fix_per_early_message,
    (rrs.distinct_fix_cnt::DECIMAL(15, 6) / NULLIF(irc.early_fix_cnt, 0))::DECIMAL(12, 6) AS fix_per_early_fix,
    false AS is_synthetic_row
  FROM {{ ref('int_releases') }} AS rel
  LEFT JOIN {{ ref('int_release_summary') }} AS rrs ON rel.release_dt = rrs.release_dt
  LEFT JOIN {{ ref('int_release_cycles') }} AS irc ON rel.release_dt = irc.ships_at_dt
)

SELECT * FROM real_members
UNION ALL
SELECT
  {{ unknown_key() }} AS dim_release_key,
  DATE '{{ var('past_eternity') }}' AS release_dt,
  DATE '{{ var('past_eternity') }}' AS wrap_dt,
  'unknown' AS status,
  false AS is_out_of_band,
  false AS is_partial_window,
  false AS is_announced,
  'Unknown' AS versions,
  null AS release_cnt,
  null AS distinct_fix_cnt,
  null AS distinct_cve_cnt,
  null AS security_fix_cnt,
  null AS committed_fix_cnt,
  null AS documentation_rate,
  null AS cycle_start_dt,
  null AS window_days,
  null AS early_report_cnt,
  null AS early_message_cnt,
  null AS early_fix_cnt,
  null AS full_fix_cnt,
  null AS first_window_fix_cnt,
  null AS early_fix_share,
  null AS fix_per_early_report,
  null AS fix_per_early_message,
  null AS fix_per_early_fix,
  true AS is_synthetic_row
UNION ALL
SELECT
  {{ not_applicable_key() }} AS dim_release_key,
  DATE '{{ var('future_eternity') }}' AS release_dt,
  DATE '{{ var('future_eternity') }}' AS wrap_dt,
  'not applicable' AS status,
  false AS is_out_of_band,
  false AS is_partial_window,
  false AS is_announced,
  'Not applicable' AS versions,
  null AS release_cnt,
  null AS distinct_fix_cnt,
  null AS distinct_cve_cnt,
  null AS security_fix_cnt,
  null AS committed_fix_cnt,
  null AS documentation_rate,
  null AS cycle_start_dt,
  null AS window_days,
  null AS early_report_cnt,
  null AS early_message_cnt,
  null AS early_fix_cnt,
  null AS full_fix_cnt,
  null AS first_window_fix_cnt,
  null AS early_fix_share,
  null AS fix_per_early_report,
  null AS fix_per_early_message,
  null AS fix_per_early_fix,
  true AS is_synthetic_row
UNION ALL
-- the in-progress major's GA-to-be (e.g. 19.0): a first-class in_development
-- release. No real date or measures yet (all forward-looking), so date- and
-- status-filtered charts leave it out. Sourced from the in-beta major.
SELECT
  {{ dbt_utils.generate_surrogate_key(["smd.major || '.0'"]) }} AS dim_release_key,
  DATE '{{ var('future_eternity') }}' AS release_dt,
  DATE '{{ var('future_eternity') }}' AS wrap_dt,
  'in_development' AS status,
  false AS is_out_of_band,
  false AS is_partial_window,
  false AS is_announced,
  smd.major || '.0' AS versions,
  1::BIGINT AS release_cnt,
  null AS distinct_fix_cnt,
  null AS distinct_cve_cnt,
  null AS security_fix_cnt,
  null AS committed_fix_cnt,
  null AS documentation_rate,
  null AS cycle_start_dt,
  null AS window_days,
  null AS early_report_cnt,
  null AS early_message_cnt,
  null AS early_fix_cnt,
  null AS full_fix_cnt,
  null AS first_window_fix_cnt,
  null AS early_fix_share,
  null AS fix_per_early_report,
  null AS fix_per_early_message,
  null AS fix_per_early_fix,
  -- the in-progress major's GA-to-be is a real forward-looking release
  false AS is_synthetic_row
FROM {{ ref('int_major_development') }} AS smd
WHERE smd.dev_status = 'beta'
