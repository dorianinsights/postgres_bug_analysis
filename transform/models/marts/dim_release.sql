-- Release dimension: one row per PostgreSQL release, unifying what were
-- dim_release_wave (shipped waves, with measures) and dim_release_cycle (all
-- cycles incl. the open/future ones). A wave is a shipped cycle, so they are one
-- entity at different lifecycle stages, captured by `status`:
--   shipped  a past release wave (scheduled OR out-of-band) — actual measures
--   open     the in-flight cycle (its wrap has passed, ships next) — no measures
--   future   an upcoming scheduled release not yet started — no measures
-- Projections for the open/future releases live in their own conforming facts
-- (fix_projection_estimates, projections), not here — a forecast is a band of
-- estimators, not a single measure. release_key is the release day's YYYYMMDD;
-- fct_release_cycles (cycle grain) and fct_fixes (wave_key) conform to it.
-- Grain = release_key. -> ../data/derived/dim_release.csv
WITH next_release AS (
  SELECT MIN(scheduled_release_dt) AS release_dt
  FROM {{ ref('int_release_calendar') }}
  WHERE scheduled_release_dt > CURRENT_DATE
),

shipped AS (
  SELECT
    wvs.wave_dt AS release_dt,
    cal.wrap_dt,
    'shipped' AS status,
    wvs.is_out_of_band,
    wvs.is_partial_window,
    wvs.versions,
    wvs.release_cnt,
    wvs.distinct_fix_cnt,
    wvs.distinct_cve_cnt,
    wvs.security_fix_cnt
  FROM {{ ref('int_wave_summary') }} AS wvs
  LEFT JOIN {{ ref('int_release_calendar') }} AS cal ON wvs.wave_dt = cal.scheduled_release_dt
),

upcoming AS (
  SELECT
    cal.scheduled_release_dt AS release_dt,
    cal.wrap_dt,
    CASE WHEN cal.scheduled_release_dt = nxt.release_dt THEN 'open' ELSE 'future' END AS status,
    false AS is_out_of_band,
    false AS is_partial_window,
    null::VARCHAR AS versions,
    null::BIGINT AS release_cnt,
    null::BIGINT AS distinct_fix_cnt,
    null::BIGINT AS distinct_cve_cnt,
    null::BIGINT AS security_fix_cnt
  FROM {{ ref('int_release_calendar') }} AS cal, next_release AS nxt
  WHERE cal.scheduled_release_dt > CURRENT_DATE
),

combined AS (
  SELECT * FROM shipped
  UNION ALL
  SELECT * FROM upcoming
)

SELECT
  STRFTIME(release_dt, '%Y%m%d')::INTEGER AS release_key,
  release_dt,
  wrap_dt,
  status,
  is_out_of_band,
  is_partial_window,
  versions,
  release_cnt,
  distinct_fix_cnt,
  distinct_cve_cnt,
  security_fix_cnt
FROM combined
