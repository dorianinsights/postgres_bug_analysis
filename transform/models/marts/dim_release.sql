-- Release dimension: one row per PostgreSQL release, unifying what were
-- dim_release_wave (shipped waves, with measures) and dim_release_cycle (all
-- cycles incl. the open/future ones). A wave is a shipped cycle, so they are one
-- entity at different lifecycle stages, captured by `status`:
--   shipped  a past release wave (scheduled OR out-of-band) — actual measures
--   open     the in-flight cycle (its wrap has passed, ships next) — no measures
--   future   an upcoming scheduled release not yet started — no measures
-- Projections for the open/future releases live in their own conforming facts
-- (fix_projection_estimates, projections), not here — a forecast is a band of
-- estimators, not a single measure. The cycle signals (int_release_cycles,
-- once a standalone fct_release_cycles) are folded in on the same row: a cycle
-- IS a release earlier in its life, so it was a fact 1:1 with this dimension.
-- They are non-NULL only for the started scheduled cycles. release_key is the
-- release day's YYYYMMDD; fct_fixes (wave_key) conforms to it.
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

-- each active major's next minor is its latest release tag's minor + 1; the
-- Nth upcoming wave adds N (open = +1, the wave after = +2, ...)
active_majors AS (
  SELECT
    major,
    MAX(minor) AS latest_minor
  FROM {{ ref('stg_git_tags') }}
  GROUP BY major
),

upcoming_dates AS (
  SELECT
    cal.scheduled_release_dt AS release_dt,
    cal.wrap_dt,
    CASE WHEN cal.scheduled_release_dt = nxt.release_dt THEN 'open' ELSE 'future' END AS status,
    ROW_NUMBER() OVER (ORDER BY cal.scheduled_release_dt) AS wave_offset
  FROM {{ ref('int_release_calendar') }} AS cal, next_release AS nxt
  WHERE cal.scheduled_release_dt > CURRENT_DATE
),

upcoming AS (
  SELECT
    udt.release_dt,
    udt.wrap_dt,
    udt.status,
    false AS is_out_of_band,
    false AS is_partial_window,
    -- the version numbers are known ahead of the release (next minor per major);
    -- the fix/CVE/security counts are not (CVEs embargoed until wrap), so NULL
    STRING_AGG(amj.major || '.' || (amj.latest_minor + udt.wave_offset), ' / ' ORDER BY amj.major) AS versions,
    COUNT(*)::BIGINT AS release_cnt,
    null::BIGINT AS distinct_fix_cnt,
    null::BIGINT AS distinct_cve_cnt,
    null::BIGINT AS security_fix_cnt
  FROM upcoming_dates AS udt
  CROSS JOIN active_majors AS amj
  GROUP BY udt.release_dt, udt.wrap_dt, udt.status
),

combined AS (
  SELECT * FROM shipped
  UNION ALL
  SELECT * FROM upcoming
)

SELECT
  STRFTIME(cmb.release_dt, '%Y%m%d')::INTEGER AS release_key,
  cmb.release_dt,
  cmb.wrap_dt,
  cmb.status,
  cmb.is_out_of_band,
  cmb.is_partial_window,
  cmb.versions,
  cmb.release_cnt,
  cmb.distinct_fix_cnt,
  cmb.distinct_cve_cnt,
  cmb.security_fix_cnt,
  -- cycle signals (folded in from the retired fct_release_cycles): non-NULL
  -- only for the started scheduled cycles, NULL for out-of-band waves and the
  -- not-yet-started future release
  irc.cycle_start_dt,
  irc.window_days,
  irc.early_report_cnt,
  irc.early_message_cnt,
  irc.early_fix_cnt,
  irc.full_fix_cnt
FROM combined AS cmb
LEFT JOIN {{ ref('int_release_cycles') }} AS irc ON cmb.release_dt = irc.ships_at_dt
