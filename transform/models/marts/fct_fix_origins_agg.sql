-- Distinct fixes per wave split by origin — where each release's fixes
-- actually came from: filed bug reports, hackers-list development, or no
-- public trail (split into embargoed security work vs the genuinely
-- unsourceable). Carries is_out_of_band so consumers can exclude the
-- surprise emergency waves (tiny denominators that distort shares).
-- Feeds the origin-share charts and future projections of how report
-- volume translates into fix volume.
SELECT
  reps.wave_dt,
  waves.is_out_of_band,
  COALESCE(
    org.origin,
    CASE
      WHEN reps.category IN ('Security (CVE)', 'Security hardening (no CVE)')
        THEN 'unknown_or_internal_security'
      ELSE 'unknown_or_internal_not_security'
    END
  ) AS origin,
  COUNT(*) AS fix_cnt
FROM {{ ref('int_fix_reps') }} AS reps
INNER JOIN {{ ref('int_waves') }} AS waves ON reps.wave_dt = waves.wave_dt
LEFT JOIN {{ ref('int_fix_origins') }} AS org ON reps.item_ord = org.group_ord
GROUP BY ALL
