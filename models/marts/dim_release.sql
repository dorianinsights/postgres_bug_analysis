{% set columns = [
  'dim_release_key', 'release_dt', 'wrap_dt', 'status', 'is_out_of_band', 'is_partial_window',
  'is_announced', 'versions', 'release_cnt', 'distinct_fix_cnt', 'distinct_cve_cnt',
  'security_fix_cnt', 'committed_fix_cnt', 'documentation_rate', 'cycle_start_dt', 'window_days',
  'early_report_cnt', 'early_message_cnt', 'early_fix_cnt', 'full_fix_cnt', 'first_window_fix_cnt',
  'early_fix_share', 'fix_per_early_report', 'fix_per_early_message', 'fix_per_early_fix',
  'is_synthetic_row',
] %}

WITH fix_counts AS (
  SELECT
    release_dt,
    COUNT(*) AS distinct_fix_cnt,
    COUNT(*) FILTER (WHERE cves IS NOT null) AS security_fix_cnt
  FROM {{ ref('int_fix_reps') }}
  GROUP BY ALL
),

cve_counts AS (
  SELECT
    release_dt,
    COUNT(DISTINCT cve_id) AS distinct_cve_cnt
  FROM {{ ref('int_fix_cves') }}
  GROUP BY ALL
),

committed_counts AS (
  SELECT
    release_dt,
    COUNT(*) AS committed_fix_cnt
  FROM {{ ref('int_committed_fixes') }}
  GROUP BY ALL
),

-- shipped releases only: the upcoming ones have no items yet
shipped_measures AS (
  SELECT
    rel.release_dt,
    COALESCE(fix.distinct_fix_cnt, 0) AS distinct_fix_cnt,
    COALESCE(cve.distinct_cve_cnt, 0) AS distinct_cve_cnt,
    COALESCE(fix.security_fix_cnt, 0) AS security_fix_cnt,
    COALESCE(cmt.committed_fix_cnt, 0) AS committed_fix_cnt,
    -- documented fixes per committed fix; NULL when nothing was committed
    (
      COALESCE(fix.distinct_fix_cnt, 0)::DECIMAL(15, 6) / NULLIF(cmt.committed_fix_cnt, 0)
    )::DECIMAL(7, 6) AS documentation_rate
  FROM {{ ref('int_releases') }} AS rel
  LEFT JOIN fix_counts AS fix ON rel.release_dt = fix.release_dt
  LEFT JOIN cve_counts AS cve ON rel.release_dt = cve.release_dt
  LEFT JOIN committed_counts AS cmt ON rel.release_dt = cmt.release_dt
  WHERE rel.status = 'shipped'
)

SELECT
  rel.dim_release_key,
  rel.release_dt,
  rel.wrap_dt,
  rel.status,
  rel.is_out_of_band,
  rel.is_partial_window,
  rel.is_announced,
  rel.versions,
  rel.release_cnt,
  rrs.distinct_fix_cnt,
  rrs.distinct_cve_cnt,
  rrs.security_fix_cnt,
  rrs.committed_fix_cnt,
  rrs.documentation_rate,
  -- cycle signals: non-NULL only for the started scheduled cycles
  irc.cycle_start_dt,
  irc.window_days,
  irc.early_report_cnt,
  irc.early_message_cnt,
  irc.early_fix_cnt,
  irc.full_fix_cnt,
  irc.first_window_fix_cnt,
  -- front-loading: the share of a cycle's fixes landing in the fixed first window
  (irc.first_window_fix_cnt::DECIMAL(15, 6) / NULLIF(irc.full_fix_cnt, 0))::DECIMAL(7, 6) AS early_fix_share,
  -- shipped-per-early-signal ratios at the open cycle's age: the scaling
  -- factors fct_fix_projections replays
  (rrs.distinct_fix_cnt::DECIMAL(15, 6) / NULLIF(irc.early_report_cnt, 0))::DECIMAL(12, 6) AS fix_per_early_report,
  (rrs.distinct_fix_cnt::DECIMAL(15, 6) / NULLIF(irc.early_message_cnt, 0))::DECIMAL(12, 6) AS fix_per_early_message,
  (rrs.distinct_fix_cnt::DECIMAL(15, 6) / NULLIF(irc.early_fix_cnt, 0))::DECIMAL(12, 6) AS fix_per_early_fix,
  false AS is_synthetic_row
FROM {{ ref('int_releases') }} AS rel
LEFT JOIN shipped_measures AS rrs ON rel.release_dt = rrs.release_dt
LEFT JOIN {{ ref('int_release_cycles') }} AS irc ON rel.release_dt = irc.ships_at_dt
{{ special_member_rows(
  'dim_release_key', columns,
  unknown={
    'release_dt': past_eternity_dt(), 'wrap_dt': past_eternity_dt(), 'status': "'unknown'",
    'is_out_of_band': 'false', 'is_partial_window': 'false', 'is_announced': 'false',
    'versions': "'Unknown'",
  },
  not_applicable={
    'release_dt': future_eternity_dt(), 'wrap_dt': future_eternity_dt(), 'status': "'not applicable'",
    'is_out_of_band': 'false', 'is_partial_window': 'false', 'is_announced': 'false',
    'versions': "'Not applicable'",
  },
) }}
UNION ALL
-- the in-progress major's GA-to-be (e.g. 19.0): a real forward-looking release
-- with no date or measures yet
SELECT
  {{ dbt_utils.generate_surrogate_key(["smd.major || '.0'"]) }} AS dim_release_key,
  {{ future_eternity_dt() }} AS release_dt,
  {{ future_eternity_dt() }} AS wrap_dt,
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
  false AS is_synthetic_row
FROM {{ ref('int_major_development') }} AS smd
WHERE smd.dev_status = 'beta'
