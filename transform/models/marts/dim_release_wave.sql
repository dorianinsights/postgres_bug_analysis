-- Release-wave dimension: one row per same-day release wave, with its scale
-- (fixes, CVEs, security fixes) and flags, plus the wrap date (content cutoff)
-- for scheduled waves from the release calendar (NULL for out-of-band waves,
-- which are not on the calendar). A conformed dimension for the star; the
-- existing wave-grain marts can migrate onto wave_key over time. Grain =
-- wave_key. -> ../data/derived/dim_release_wave.csv
SELECT
  STRFTIME(wvs.wave_dt, '%Y%m%d')::INTEGER AS wave_key,
  drc.cycle_key,
  wvs.wave_dt,
  cal.wrap_dt,
  wvs.versions,
  wvs.release_cnt,
  wvs.distinct_fix_cnt,
  wvs.distinct_cve_cnt,
  wvs.security_fix_cnt,
  wvs.is_out_of_band,
  wvs.is_partial_window
FROM {{ ref('int_wave_summary') }} AS wvs
LEFT JOIN {{ ref('int_release_calendar') }} AS cal
  ON wvs.wave_dt = cal.scheduled_release_dt
LEFT JOIN {{ ref('dim_release_cycle') }} AS drc ON wvs.wave_dt = drc.ships_at_dt
